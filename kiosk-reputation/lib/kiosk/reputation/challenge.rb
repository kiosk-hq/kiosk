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
    #   3. Re-derive the demanded alg/params from the CALLER's live config and
    #      compare them with what the challenge names (string compare).
    #      → :bad_params on mismatch  (see below)
    #   4. ONLY THEN call the backend .verify (one Equihash proof check).
    #      → :ok if the proof is valid, :bad_proof otherwise
    #
    # Steps 1–3 reject floods of forged/expired/off-spec proofs without burning
    # a backend eval. The expensive backend is invoked exactly once per
    # well-formed, unexpired, on-spec, correctly-bound proof.
    #
    # == Server-side parameter re-derivation (K-541)
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
    # `expect:` is optional (a caller that omits it gets the pre-K-541
    # behaviour); `kiosk-server`'s gate always passes it. The comparison uses
    # the same canonical `k=v` rendering the sig covers, so it is insensitive to
    # key order, Symbol-vs-String keys, and Integer-vs-String JSON typing — it
    # rejects exactly the challenges the sig would have let through, no more.
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
      # Delimiter between canonical-string fields. Must not appear in field values.
      OUTER_DELIM = "|"
      # Delimiter between param key=value pairs.
      PARAM_DELIM = ","
      # Key=value separator inside a param pair.
      KV_DELIM = "="

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
        def issue(alg:, params:, request_fingerprint:, secret:, ttl:,
                  now: Time.now.to_i,
                  salt: SecureRandom.bytes(16),
                  id: SecureRandom.uuid)
          salt_b64 = Base64.strict_encode64(salt)
          exp      = now + ttl
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
        #   though its sig is valid (K-541). Omit to skip the check.
        # @return [Symbol] :ok | :bad_sig | :expired | :bad_params | :bad_proof
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

          # --- Step 3 (CHEAP): parameters must still be the ones we demand ---
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

        # Does the challenge still name the algorithm + parameters the caller's
        # live configuration demands? (K-541 — server-side re-derivation.)
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
          # value — matching Policies::Backoff's is_a?(Hash) convention (K-574).
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
