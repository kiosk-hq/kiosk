# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"

module Kiosk
  module Reputation
    # Stateless, request-bound wire challenge.
    #
    # == Issue
    #
    # The provider calls {.issue} to build a signed challenge hash to embed in
    # a `pow_required` (HTTP 402) response. The challenge is self-contained:
    # the HMAC sig covers the challenge fields AND a fingerprint of the original
    # request, so the server needs no storage to trust it, and a proof cannot be
    # replayed against a different request.
    #
    # == Verify (anti-DoS ordering — cheap checks first)
    #
    # {.verify} enforces a strict cheap-before-expensive evaluation order:
    #
    #   1. Recompute + compare HMAC sig (cheap HMAC + constant-time compare).
    #      → :bad_sig on mismatch  (forged, tampered, or wrong-request proof)
    #   2. Check exp > now (integer comparison).
    #      → :expired if passed
    #   3a. Reject a challenge whose fields carry a canonical-string delimiter
    #      (string scan). Such a challenge has a SECOND pre-image, so one sig
    #      covers two different (alg, params) splits; {.issue} cannot mint one,
    #      so this is never an honest client.
    #      → :bad_params
    #   3b. Re-derive the demanded alg/params from the CALLER's live config and
    #      compare them with what the challenge names (string compare).
    #      → :bad_params on mismatch  (see below)
    #   4. ONLY THEN call the backend .verify (one Equihash proof check).
    #      → :ok if the proof is valid, :bad_proof otherwise
    #
    # Steps 1–3 reject floods of forged/expired/off-spec proofs without burning
    # a backend eval. The expensive backend is invoked exactly once per
    # well-formed, unexpired, on-spec, correctly-bound proof.
    #
    # == Server-side parameter re-derivation
    #
    # The challenge is stateless, so `alg`/`params` travel on the wire and come
    # back from the client. The HMAC sig proves WE minted them — it does NOT
    # prove they are still the difficulty this server demands. Pass `expect:`
    # (the spec the caller just re-derived from its own configuration) and
    # {.verify} rejects any challenge naming other parameters, however valid
    # its sig. Two things this buys:
    #
    #   * a challenge minted just before a difficulty raise stops being
    #     solvable at the old, cheap parameters for the rest of its TTL;
    #   * if the HMAC secret ever leaks, a self-signed `{n: 8, k: 1}` challenge
    #     is still refused — the toll degrades, it does not vanish.
    #
    # `expect:` is optional — a caller that omits it accepts any validly signed
    # challenge, whatever parameters it names; `kiosk-server`'s gate always
    # passes it. The comparison uses the same canonical `k=v` rendering the sig
    # covers, so it is insensitive to key order, Symbol-vs-String keys, and
    # Integer-vs-String JSON typing — it rejects exactly the challenges the sig
    # would have let through, no more.
    #
    # NOTE for policy authors: `:bad_params` means "re-challenge", not "bad
    # faith". A policy whose params legitimately vary per identity will simply
    # re-issue at the current parameters when the client's factors moved.
    #
    # == Spent-id set
    #
    # Challenge is stateless. The CALLER (kiosk-server) is responsible for
    # maintaining a small spent-id set (TTL ≤ challenge[:exp]) to prevent
    # replay of a valid, unexpired proof. {.verify} does NOT track spent ids.
    module Challenge
      # Delimiter between canonical-string fields. Must not appear in field
      # values, and {delimiter_offence} is what holds that: {.issue} refuses to
      # mint a challenge carrying one and {.verify} answers :bad_params for a
      # submitted challenge that does.
      OUTER_DELIM = "|"
      # Delimiter between param key=value pairs. Same invariant, same guard —
      # a param key or value carrying one re-partitions {params_string}.
      PARAM_DELIM = ","
      # Key=value separator inside a param pair. Same invariant, same guard.
      KV_DELIM = "="

      # Every delimiter the canonical string is built from, for the one guard
      # that enforces the invariant the three declare.
      DELIMITERS = [OUTER_DELIM, PARAM_DELIM, KV_DELIM].freeze

      class << self
        # Build a signed, request-bound challenge hash.
        #
        # @param alg                [String]  algorithm name (e.g. "equihash")
        # @param params             [Hash]    algorithm-specific params (e.g. {n:,k:})
        # @param request_fingerprint [String] opaque hash of the original request
        # @param secret             [String]  HMAC key (provider secret; raw bytes or ASCII)
        # @param ttl                [Integer] validity window in seconds
        # @param now                [Integer] current Unix timestamp (injectable for tests)
        # @param salt               [String]  raw bytes for the PoW salt (injectable for tests)
        # @param id                 [String]  opaque challenge id (injectable for tests)
        # @return [Hash] wire challenge: {id:, alg:, params:, salt: <base64>, exp:, sig:}
        # @raise [ArgumentError] when a field would make the signed canonical
        #   string ambiguous (see {delimiter_offence}), or when `params` is not
        #   a Hash (see {params_string})
        def issue(alg:, params:, request_fingerprint:, secret:, ttl:,
                  now: Time.now.to_i,
                  salt: SecureRandom.bytes(16),
                  id: SecureRandom.uuid)
          salt_b64 = Base64.strict_encode64(salt)
          exp      = now + ttl

          offence = delimiter_offence(id, alg, params, salt_b64, exp, request_fingerprint)
          if offence
            raise ArgumentError,
              "challenge field would make the signed canonical string ambiguous: #{offence}. " \
              "Fix the source of the value: the `alg`/`params` your reputation_policy returns " \
              "from #challenge_for, or `c.registration_pow_params` for POST /auth/register."
          end

          sig      = compute_sig(secret, id, alg, params, salt_b64, exp, request_fingerprint)

          { id: id, alg: alg, params: params, salt: salt_b64, exp: exp, sig: sig }
        end

        # Verify a submitted proof against the original challenge.
        #
        # @param challenge          [Hash]    the challenge hash from {.issue}
        # @param nonce              [#to_s]   the proof nonce submitted by the client
        # @param request_fingerprint [String] fingerprint of the request being proved
        # @param secret             [String]  HMAC key (must match the key used in {.issue})
        # @param now                [Integer] current Unix timestamp
        # @param expect             [Hash, nil] `{alg:, params:}` the caller
        #   re-derived from its OWN live config for this request. When given,
        #   a challenge naming anything else is rejected with :bad_params even
        #   though its sig is valid. Omit to skip the check.
        # @return [Symbol] :ok | :bad_sig | :expired | :bad_params | :bad_proof
        # @raise [KeyError] when the challenge names an algorithm no backend is
        #   registered under. A challenge that reaches the backend step was
        #   minted by THIS host (its sig verified) and no caller can move the
        #   `alg` past step 3a, so this is an operator misconfiguration — the
        #   registry names what IS registered rather than answering :bad_proof
        #   for a difficulty nobody can evaluate.
        def verify(challenge:, nonce:, request_fingerprint:, secret:, now:, expect: nil)
          id       = challenge[:id]
          alg      = challenge[:alg]
          params   = challenge[:params]
          salt_b64 = challenge[:salt]
          exp      = challenge[:exp]
          stored_sig = challenge[:sig].to_s

          # --- Step 1 (CHEAP): sig check + request binding ---
          expected_sig = compute_sig(secret, id, alg, params, salt_b64, exp, request_fingerprint)
          return :bad_sig unless constant_time_compare(expected_sig, stored_sig)

          # --- Step 2 (CHEAP): expiry check ---
          return :expired unless exp.to_i > now.to_i

          # --- Step 3a (CHEAP): the signed string must have ONE pre-image ---
          # A submitted field carrying a delimiter re-partitions the canonical
          # string, so the honest challenge's sig verifies over a DIFFERENT
          # (alg, params) split — a substituted backend under a valid signature.
          # {.issue} cannot mint such a challenge, so an honest client can never
          # echo one back; but it is not chargeable bad faith either (no hash
          # loop ran and no backend was named), so it takes the re-challenge
          # outcome rather than :bad_proof.
          return :bad_params if delimiter_offence(id, alg, params, salt_b64, exp, request_fingerprint)

          # --- Step 3b (CHEAP): parameters must still be the ones we demand ---
          # The sig only proves WE minted this challenge; `expect` is what this
          # server demands RIGHT NOW. Both must hold before we spend a hash loop.
          return :bad_params unless matches_expected?(expect, alg, params)

          # --- Step 4 (EXPENSIVE): one backend eval ---
          raw_salt   = Base64.strict_decode64(salt_b64)
          sym_params = symbolize_keys(params)
          result     = Backends.fetch(alg).verify(salt: raw_salt, params: sym_params, nonce: nonce)
          result ? :ok : :bad_proof
        end

        private

        # The invariant {OUTER_DELIM}, {PARAM_DELIM} and {KV_DELIM} declare,
        # enforced — the one thing that makes {canonical_string} injective.
        #
        # The canonical string joins six fields with OUTER_DELIM and renders
        # params as `k=v` pairs joined with PARAM_DELIM. A delimiter INSIDE a
        # value gives that string a second pre-image, and both halves of the
        # ambiguity are live: an `alg` of `equi|hash` with params `{n:,k:}`
        # renders exactly as an `alg` of `equi` with params `{"hash|k" => …}`,
        # and params `{n: 168, k: 7}` render exactly as `{"k=7,n" => "168"}`.
        # Either re-partition carries the honest challenge's signature, and the
        # second needs no delimiter in any ISSUED field at all — a client can
        # mint it from a challenge it was legitimately served, and the `expect:`
        # comparison cannot see it, because both sides render to one string.
        #
        # Checked on BOTH sides deliberately: {.issue} raises so the operator
        # learns at the source, {.verify} returns :bad_params so a submitted
        # re-partition is refused whatever this host once minted.
        #
        # Only OUTER_DELIM is refused in the five scalar fields; the param
        # delimiters are meaningless outside the params rendering. A non-Hash
        # `params` is not this method's error to report — {params_string}
        # raises a typed ArgumentError naming the value.
        #
        # @return [String, nil] a message naming the offending field, or nil
        def delimiter_offence(id, alg, params, salt_b64, exp, request_fingerprint)
          { "id" => id, "alg" => alg, "salt" => salt_b64,
            "exp" => exp, "request_fingerprint" => request_fingerprint }.each do |field, value|
            if value.to_s.include?(OUTER_DELIM)
              return "#{field} #{value.to_s.inspect} contains #{OUTER_DELIM.inspect}"
            end
          end

          return nil unless params.is_a?(Hash)

          params.each do |key, value|
            DELIMITERS.each do |delim|
              return "params key #{key.to_s.inspect} contains #{delim.inspect}" if key.to_s.include?(delim)

              if value.to_s.include?(delim)
                return "params value #{value.to_s.inspect} (key #{key.to_s.inspect}) contains #{delim.inspect}"
              end
            end
          end

          nil
        end

        # Does the challenge still name the algorithm + parameters the caller's
        # live configuration demands? (The server-side re-derivation check.)
        #
        # `expect` is `{alg:, params:}` as re-derived by the caller for THIS
        # request; nil (or a nil member) means "caller did not pin this", which
        # keeps the check opt-in and backward compatible.
        #
        # Both sides are rendered with {params_string} — the exact canonical
        # form the HMAC sig already commits to. That is deliberate: the check
        # must not reject a challenge the sig would accept for a reason the sig
        # cannot see (Symbol vs String keys, key order, or `168` vs `"168"` —
        # all of which produce one identical signed string). It rejects a
        # DIFFERENT difficulty, nothing else.
        def matches_expected?(expect, alg, params)
          return true if expect.nil?

          expected_alg = expect[:alg] || expect["alg"]
          unless expected_alg.nil? || expected_alg.to_s == alg.to_s
            return false
          end

          expected_params = expect[:params] || expect["params"]
          return true if expected_params.nil?

          params_string(expected_params) == params_string(params)
        end

        # Recompute the HMAC-SHA256 hex digest over the canonical challenge string.
        def compute_sig(secret, id, alg, params, salt_b64, exp, request_fingerprint)
          OpenSSL::HMAC.hexdigest("SHA256", secret, canonical_string(id, alg, params, salt_b64, exp, request_fingerprint))
        end

        # Stable canonical string for HMAC. Keys are sorted so that Hash key
        # ordering does not affect the sig. Both issue and verify must call this
        # with the same inputs to produce the same sig.
        #
        # Format: id|alg|k=7,n=168|<salt_b64>|<exp>|<fingerprint>
        # (params sorted by key, joined with comma; fields joined with pipe)
        def canonical_string(id, alg, params, salt_b64, exp, request_fingerprint)
          [id, alg, params_string(params), salt_b64, exp.to_s, request_fingerprint].join(OUTER_DELIM)
        end

        # Canonical `k=v,k=v` rendering of a params Hash: keys sorted by their
        # string form, values stringified. This is the ONLY place params enter
        # the signed material, and {matches_expected?} reuses it so the
        # re-derivation check and the sig share one notion of equality.
        def params_string(params)
          # Guard the root-cause line: a nil/non-Hash params otherwise raises a
          # cryptic NoMethodError deep in the gem (a 500 at any surface that does
          # not pre-guard). Fail loud with a typed, rescuable error naming the bad
          # value — matching Policies::Backoff's is_a?(Hash) convention.
          unless params.is_a?(Hash)
            raise ArgumentError, "params must be a Hash (got #{params.inspect})"
          end

          params
            .sort_by { |k, _| k.to_s }
            .map { |k, v| "#{k}#{KV_DELIM}#{v}" }
            .join(PARAM_DELIM)
        end

        # Constant-time string comparison to prevent timing attacks.
        # Returns false immediately if lengths differ (safe: HMAC hex digests are
        # always exactly 64 chars; length mismatch means a corrupted/forged sig).
        def constant_time_compare(a, b)
          return false if a.bytesize != b.bytesize
          OpenSSL.fixed_length_secure_compare(a, b)
        end

        # Ensure params keys are symbols before passing to a backend.
        def symbolize_keys(hash)
          hash.transform_keys(&:to_sym)
        end
      end
    end
  end
end
