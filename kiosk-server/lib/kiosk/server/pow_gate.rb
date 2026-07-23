# frozen_string_literal: true

require "digest"
require "json"

module Kiosk
  module Server
    # PoW challenge-response gate (R2 protocol hook).
    #
    # Called by {WireController#run_command} AFTER identity resolution and BEFORE
    # {Executor.call}. When `Kiosk.configuration.reputation_policy` is nil
    # (the default), {.gate} returns `:proceed` immediately — zero overhead,
    # no `kiosk-reputation` references evaluated. This is the invariant that
    # keeps all existing tests, demos, and e2e flows byte-for-byte unchanged.
    #
    # == Soft dependency on kiosk-reputation
    #
    # `kiosk-server` does NOT hard-require `kiosk-reputation` at load time.
    # References to `Kiosk::Reputation::*` only appear inside the policy-present
    # branch of {.gate}. A host that sets `reputation_policy` is expected to
    # have `kiosk-reputation` (and its configured backend) already loaded; if it
    # isn't, {.gate} raises {Errors::ConfigurationError} with a clear message.
    #
    # == Anti-DoS cheap-before-expensive ordering
    #
    # On a submitted proof, `Kiosk::Reputation::Challenge.verify` enforces:
    #   1. HMAC sig + request-fingerprint binding (cheap constant-time compare)
    #   2. Expiry check (integer compare)
    #   3. Equihash backend eval (at n=168 k=7: ~16-17 ms + KB of RAM to
    #      verify — memory is the asymmetry, since SOLVING the same proof
    #      costs ~1.3 GiB)
    # A flood of forged or expired proofs is rejected at step 1/2 without
    # burning a backend evaluation.
    #
    # == Spent-id set
    #
    # Valid proofs are recorded in `config.pow_spent_store` (in-process TTL
    # store by default). Providers running multiple processes must override with
    # a shared store — see {PowSpentStore}.
    module PowGate
      module_function

      # Compute the request fingerprint used for challenge binding.
      #
      # Covers `command` and the canonical (key-order-independent) JSON
      # serialisation of `body`. The `pow` field is a sibling of `body` in the
      # wire JSON and is intentionally excluded — its absence at issue time and
      # presence at verify time must produce the same fingerprint.
      #
      # @param command [String, Symbol]
      # @param body    [Hash, nil]
      # @return [String] SHA-256 hex digest
      def request_fingerprint(command:, body:)
        Digest::SHA256.hexdigest("#{command}\n#{canonical_json(body || {})}")
      end

      # Gate a request through the reputation policy.
      #
      # @param identity [Kiosk::Identity]
      # @param command  [String, Symbol]  the Kiosk verb
      # @param body     [Hash, nil]       the verb args (must NOT include the `pow` key)
      # @param pow      [Hash, nil]       submitted proof `{challenge:, nonce:}`, or nil
      #
      # @return [:proceed]  when the request may proceed to {Executor}
      # @raise  [Errors::PowRequired]       (HTTP 402) when a challenge must be solved
      # @raise  [Errors::Forbidden]         (HTTP 403) when a submitted proof is invalid
      # @raise  [Errors::ConfigurationError] when the policy is set but pow_secret is missing
      def gate(identity:, command:, body:, pow:)
        config = Kiosk.configuration
        policy = config.reputation_policy

        # ── Fast path (default, nil policy) ──────────────────────────────────
        # No kiosk-reputation references evaluated here. This is the ONLY path
        # exercised by the ~389 existing specs — byte-for-byte unchanged.
        return :proceed if policy.nil?

        # ── Policy present: guard checks ─────────────────────────────────────

        unless defined?(::Kiosk::Reputation)
          raise Errors::ConfigurationError,
            "Kiosk::Server: reputation_policy is set but kiosk-reputation is not loaded. " \
            "Add `require 'kiosk/reputation'` (and `gem 'kiosk-reputation'`) to your app."
        end

        secret = config.pow_secret
        if secret.nil? || secret.to_s.strip.empty?
          raise Errors::ConfigurationError,
            "Kiosk::Server: reputation_policy is set but pow_secret is nil or empty. " \
            "Set: Kiosk.configure { |c| c.pow_secret = ENV.fetch('KIOSK_POW_SECRET') }"
        end

        # ── Ask the policy ───────────────────────────────────────────────────

        fp      = request_fingerprint(command: command, body: body)
        # Anonymous (identity-less) requests reach the gate on PUBLIC verbs
        # (schema): there is no principal to compute per-identity reputation for,
        # so use empty factors. The policy still decides whether to challenge —
        # it receives identity: nil and MUST check the verb before dereferencing
        # identity (the shipped demo policies return early on non-target verbs).
        factors = if identity.nil?
                    ::Kiosk::Reputation::Factors.empty
                  else
                    config.reputation_factors.call(identity: identity, verb: command.to_sym)
                  end
        spec    = policy.challenge_for(identity: identity, verb: command.to_sym, factors: factors)

        return :proceed if spec.nil?  # policy decided not to challenge this request

        result = enforce(
          spec:         spec,
          fingerprint:  fp,
          pow:          pow,
          secret:       secret,
          config:       config,
          on_bad_proof: -> { config.on_bad_proof.call(identity: identity) },
        )

        # ── Post-verify hook (duck-typed, opt-in) ────────────────────────────
        # We only reach here when `enforce` verified the submitted proof(s)
        # without raising (a real solve). Policies that define
        # #on_proof_verified (e.g. the count-based Backoff strategy) use this to
        # record the solve — e.g. grant the identity N ungated follow-up calls.
        # Duck-typed: a policy without the hook (RateAndReputation, the base
        # Policy, …) is completely unaffected. Never reached on the nil-spec
        # path above (no enforce ran → no new grant).
        # Grant follow-up credits only to a RESOLVED principal. An anonymous
        # caller (identity nil — e.g. an unauthenticated `schema` read) must NOT
        # accumulate a backoff grant: the grant is keyed by identity, so a nil
        # identity would share ONE bucket across every anonymous caller (one
        # solve → free ungated reads for the whole internet). Anonymous tolled
        # requests therefore pay a fresh proof every time; a replayed proof is
        # already rejected by the spent-id set above.
        if !identity.nil? && policy.respond_to?(:on_proof_verified)
          policy.on_proof_verified(identity: identity)
        end

        result
      end

      # Verify a set of submitted proofs against a `spec` bound to `fingerprint`,
      # or raise to demand them. Shared by the reputation gate ({.gate}) and the
      # registration gate ({RegistrationPow}), which differ only in how they
      # derive `spec`/`fingerprint` and whether a principal exists yet.
      #
      # @param spec         [Hash]     `{alg:, params:, count:}` (count defaults to 1)
      # @param fingerprint  [String]   request fingerprint the challenges bind to
      # @param pow          [Hash, nil] submitted proof(s)
      # @param secret       [String]   HMAC key for challenge sig
      # @param config       [Kiosk::Configuration]
      # @param on_bad_proof [#call]    invoked on a cryptographically invalid proof
      # @return [:proceed]
      # @raise  [Errors::PowRequired] (402) when more valid proofs are needed
      # @raise  [Errors::Forbidden]   (403) on a bad-faith (wrong) proof
      def enforce(spec:, fingerprint:, pow:, secret:, config:, on_bad_proof:)
        # ── How many independent proofs must this request carry? ──────────────
        # Equihash has no continuous difficulty dial — escalation is by PROOF
        # COUNT (N×PoW). Each challenge has a distinct salt, so there is no
        # amortisation across them. `count` defaults to 1 when spec omits it.
        count     = pow_count(spec)
        submitted = extract_proofs(pow)

        # ── No proof submitted — issue `count` fresh, independent challenges ──
        if submitted.empty?
          raise Errors::PowRequired.new(
            challenges: issue_challenges(count, spec, fingerprint, secret, config),
          )
        end

        # ── Proofs submitted — verify each. We need `count` DISTINCT, unspent,
        #    valid proofs to proceed. A single cryptographically WRONG proof is
        #    bad faith → 403 immediately.
        accepted = {} # challenge id => exp (dedup by id; ignores repeats)
        submitted.each do |proof|
          challenge = symbolize_keys(proof[:challenge] || proof["challenge"] || {})
          nonce     = proof[:nonce] || proof["nonce"]
          id        = challenge[:id]

          next if id.nil? || accepted.key?(id)

          # Replay: an already-spent proof does not count toward the quota, but
          # it is NOT bad faith (at-least-once HTTP retry may resend a served
          # proof) — skip it without penalty.
          next if config.pow_spent_store.spent?(id)

          # Cheap sig + expiry checks first (inside Challenge.verify), then the
          # one cheap backend eval.
          outcome = ::Kiosk::Reputation::Challenge.verify(
            challenge:            challenge,
            nonce:                nonce,
            request_fingerprint:  fingerprint,
            secret:               secret,
            now:                  Time.now.to_i,
          )

          case outcome
          when :ok
            accepted[id] = challenge[:exp].to_i
          when :bad_proof
            on_bad_proof.call
            raise Errors::Forbidden, "invalid proof of work"
          when :expired, :bad_sig
            # Doesn't count; falls through to a fresh re-challenge below if the
            # quota isn't met. No on_bad_proof (honest clock skew / retry).
          end
        end

        if accepted.size >= count
          # Spend all accepted proofs only now that the quota is met, so a
          # partial submission can be re-tried without burning valid proofs.
          accepted.each { |id, exp| config.pow_spent_store.mark_spent(id, exp) }
          :proceed
        else
          raise Errors::PowRequired.new(
            challenges: issue_challenges(count, spec, fingerprint, secret, config),
          )
        end
      end

      # Split a submitted proof out of the request body.
      #
      # On the wire `pow` is a SIBLING of the verb args (`{name:"catalog", pow:{…}}`).
      # It must be removed before the body is used for either purpose:
      #   * fingerprinting — the challenge is bound to the ORIGINAL request, which
      #     had no `pow`; leaving it in would change the fingerprint on retry and
      #     every valid proof would be rejected as `:bad_sig`.
      #   * dispatch — the {Executor} must never see the `pow` key.
      #
      # Non-mutating: returns a fresh body hash. Accepts symbol- or string-keyed
      # `pow`. Returns `[nil, arg]` unchanged for a non-Hash arg.
      #
      # @param body [Hash, Object]
      # @return [Array(Object, Object)] `[pow, body_without_pow]`
      def split_pow(body)
        return [nil, body] unless body.is_a?(Hash)

        rest = body.dup
        pow  = rest.delete(:pow)
        pow  = rest.delete("pow") if pow.nil?
        [pow, rest]
      end

      # ── Internal helpers (all module_function so they're callable from above) ──

      def blank?(obj)
        obj.nil? || (obj.respond_to?(:empty?) && obj.empty?)
      end

      def issue_challenge(spec, fp, secret, ttl)
        ::Kiosk::Reputation::Challenge.issue(
          alg:                  spec[:alg],
          params:               spec[:params],
          request_fingerprint:  fp,
          secret:               secret,
          ttl:                  ttl,
          now:                  Time.now.to_i,
        )
      end

      # Number of independent proofs the policy demands for this request.
      # Defaults to 1 (single-proof) when the spec omits `count`. Floored at 1.
      def pow_count(spec)
        n = (spec[:count] || spec["count"] || 1).to_i
        n < 1 ? 1 : n
      end

      # Issue `count` independent challenges — each gets its own random salt and
      # id (via Challenge.issue defaults) but binds to the SAME request
      # fingerprint, so all N must be solved to prove work for THIS request.
      #
      # The per-challenge TTL scales with `count`: a slow honest client solving
      # N proofs sequentially must not have the first challenge expire before it
      # reaches the last one. TTL = pow_ttl * count (min pow_ttl at count 1).
      def issue_challenges(count, spec, fp, secret, config)
        ttl = config.pow_ttl * [count, 1].max
        Array.new(count) { issue_challenge(spec, fp, secret, ttl) }
      end

      # Normalise the submitted `pow` field into a list of `{challenge:, nonce:}`
      # proofs. Accepts:
      #   * plural:   { proofs: [ {challenge:, nonce:}, ... ] }  (N×PoW wire)
      #   * singular: { challenge:, nonce: }                     (N=1 convenience)
      #   * a bare Array of proofs
      # Returns [] for anything blank/unrecognised.
      def extract_proofs(pow)
        return [] if blank?(pow)
        return pow if pow.is_a?(Array)
        return [] unless pow.is_a?(Hash)

        list = pow[:proofs] || pow["proofs"]
        return Array(list) if list
        return [pow] if pow[:challenge] || pow["challenge"]

        []
      end

      # Recursively serialise a value to JSON with all Hash keys sorted.
      # This ensures the fingerprint is key-order-independent.
      def canonical_json(obj)
        case obj
        when Hash
          pairs = obj.sort_by { |k, _| k.to_s }
                     .map { |k, v| "#{JSON.generate(k.to_s)}:#{canonical_json(v)}" }
          "{#{pairs.join(",")}}"
        when Array
          "[#{obj.map { |v| canonical_json(v) }.join(",")}]"
        else
          JSON.generate(obj)
        end
      end

      def symbolize_keys(hash)
        return {} unless hash.is_a?(Hash)

        hash.transform_keys(&:to_sym)
      end
    end
  end
end
