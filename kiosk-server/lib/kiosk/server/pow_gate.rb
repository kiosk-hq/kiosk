# frozen_string_literal: true

require "digest"
require "json"

module Kiosk
  module Server
    # The proof-of-work toll, in front of every verb that reaches the executor.
    # With no `reputation_policy` it returns `:proceed` and touches nothing;
    # `kiosk-reputation` is required only when a policy is set.
    module PowGate
      module_function

      # §10, §15.2: SHA256("<METHOD> <verb>\n<canonical args>"), so a proof is
      # spendable on this request only. The proof rides in a header, not the body.
      def request_fingerprint(method:, verb:, body:)
        Digest::SHA256.hexdigest(
          "#{method.to_s.upcase} #{verb}\n#{canonical_json(body || {})}"
        )
      end

      # `command` is the policy verb ({Executor::VERBS}); `verb` is the wire name
      # the fingerprint binds.
      def gate(identity:, command:, body:, pow:, method: "POST", verb: nil)
        config = Kiosk.configuration
        policy = config.reputation_policy

        return :proceed if policy.nil?

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

        fp      = request_fingerprint(method: method, verb: verb || command, body: body)
        factors = config.reputation_factors.call(identity: identity, verb: command.to_sym)
        spec    = policy.challenge_for(identity: identity, verb: command.to_sym, factors: factors)

        return :proceed if spec.nil?

        result = enforce(
          spec:         spec,
          fingerprint:  fp,
          pow:          pow,
          secret:       secret,
          config:       config,
          on_bad_proof: -> { config.on_bad_proof.call(identity: identity) },
        )

        # Optional policy hook, reached only after a real solve.
        if policy.respond_to?(:on_proof_verified)
          policy.on_proof_verified(identity: identity)
        end

        result
      end

      # Shared by {.gate} and {RegistrationPow}.
      def enforce(spec:, fingerprint:, pow:, secret:, config:, on_bad_proof:)
        validate_spec_params!(spec)

        # Equihash has no difficulty dial: escalation is by proof count.
        count     = pow_count(spec)
        submitted = extract_proofs(pow)

        if submitted.empty?
          raise Errors::PowRequired.new(
            challenges: issue_challenges(count, spec, fingerprint, secret, config),
          )
        end

        # `count` distinct, unspent, valid proofs; one wrong proof is a 403.
        accepted = {}
        submitted.each do |proof|
          challenge = symbolize_keys(proof[:challenge] || proof["challenge"] || {})
          nonce     = proof[:nonce] || proof["nonce"]
          id        = challenge[:id]

          next if id.nil? || accepted.key?(id)

          unless challenge[:params].is_a?(Hash)
            raise Errors::BadRequest.new(
              "malformed PoW proof: challenge.params is missing or not an object",
              hint: POW_HEADER_HINT,
            )
          end

          # Atomically claim the id as spent BEFORE the expensive verify.
          # A lost claim is a replay: skipped, not penalised.
          next unless config.pow_spent_store.claim(id, challenge[:exp].to_i)

          # `expect`: honoured only at the difficulty live config demands now.
          outcome = ::Kiosk::Reputation::Challenge.verify(
            challenge:            challenge,
            nonce:                nonce,
            request_fingerprint:  fingerprint,
            secret:               secret,
            now:                  Time.now.to_i,
            expect:               { alg: spec[:alg] || spec["alg"], params: spec[:params] || spec["params"] },
          )

          case outcome
          when :ok
            accepted[id] = challenge[:exp].to_i
          when :bad_proof
            on_bad_proof.call
            # The id stays consumed, so one challenge drives at most one verify.
            raise Errors::Forbidden.new("invalid proof of work", hint: POW_INVALID_HINT)
          when :expired, :bad_sig, :bad_params
            # Not bad faith (clock skew, a difficulty change): release the claim
            # and re-challenge below.
            config.pow_spent_store.release(id)
          end
        end

        if accepted.size >= count
          :proceed
        else
          # Released, so the retry with fresh challenges is not blocked by our own claim.
          accepted.each_key { |id| config.pow_spent_store.release(id) }
          raise Errors::PowRequired.new(
            challenges: issue_challenges(count, spec, fingerprint, secret, config),
          )
        end
      end

      # One proof, a JSON array, repeated header lines (Rack joins them with
      # "\n") or comma-joined ones; nil when absent.
      def proofs_from_header(raw)
        return nil if raw.nil?

        proofs = []
        raw.split("\n").each do |line|
          value = line.strip
          next if value.empty?

          wrapped = value.start_with?("[") ? value : "[#{value}]"
          parsed  = JSON.parse(wrapped, symbolize_names: true)
          proofs.concat(Array(parsed))
        end

        proofs.empty? ? nil : proofs
      rescue JSON::ParserError
        raise Errors::BadRequest.new(
          "malformed Kiosk-PoW header",
          hint: POW_HEADER_HINT,
        )
      end

      POW_HEADER_HINT =
        "the Kiosk-PoW header carries the proof(s) as raw minified JSON: a single " \
        "proof {\"challenge\": <the challenge object from the 402, echoed verbatim>, " \
        "\"nonce\": {\"indices\": […], \"header_nonce\"?}}, OR a JSON array of such " \
        "proofs [{…},{…}]. Repeated Kiosk-PoW header lines (one proof each) also " \
        "work. Solve every challenge issued in the pow_required 402 and echo it " \
        "back verbatim."

      # Unversioned: the server cannot know which skill cut its caller read.
      POW_SOLVER_URL = "https://kiosk.tech/pow/solve.py"

      POW_INVALID_HINT =
        "solve with the reference solver at #{POW_SOLVER_URL} — " \
        "a hand-written Equihash solver will not match this verifier"

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

      def validate_spec_params!(spec)
        alg    = spec[:alg]    || spec["alg"]
        params = spec[:params] || spec["params"]
        return if ::Kiosk::Reputation::Backends.valid_params?(alg, params)

        raise Errors::ConfigurationError,
          "Kiosk::Server: the #{alg.to_s.inspect} proof-of-work backend refuses the configured " \
          "parameters #{params.inspect} — no proof solved at them could ever verify, so every " \
          "honest client would be told its correct proof was invalid. Fix the source of the " \
          "parameters: `c.registration_pow_params` for POST /auth/register, or the `params:` " \
          "your reputation_policy returns from #challenge_for."
      end

      def pow_count(spec)
        n = (spec[:count] || spec["count"] || 1).to_i
        n < 1 ? 1 : n
      end

      # TTL scales with `count`, so the first expires no sooner than the last is solved.
      def issue_challenges(count, spec, fp, secret, config)
        ttl = config.pow_ttl * [count, 1].max
        Array.new(count) { issue_challenge(spec, fp, secret, ttl) }
      end

      def extract_proofs(pow)
        return [] if blank?(pow)
        return pow if pow.is_a?(Array)
        return [] unless pow.is_a?(Hash)

        list = pow[:proofs] || pow["proofs"]
        return Array(list) if list
        return [pow] if pow[:challenge] || pow["challenge"]

        []
      end

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
