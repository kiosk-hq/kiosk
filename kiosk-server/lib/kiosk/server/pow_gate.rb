# frozen_string_literal: true

require 'digest'
require 'json'

module Kiosk
  module Server
    # The proof-of-work toll, in front of every verb that reaches the executor.
    # The policy decides on each call; a valid proof sets the account's count of
    # tolled calls back to zero. With no `reputation_policy` it returns
    # `:proceed` and touches nothing; `kiosk-reputation` is required only when a
    # policy is set.
    module PowGate
      module_function

      # §10, §15.2: SHA256("<METHOD> <verb>\n<canonical args>"), so a proof is
      # spendable on this request only. The proof rides in a header, not the body.
      def request_fingerprint(method:, verb:, body:)
        Digest::SHA256.hexdigest(
          "#{method.to_s.upcase} #{verb}\n#{canonical_json(body || {})}"
        )
      end

      # `command` is the policy verb ({Executor::VERBS}); `verb` is the published name
      # the fingerprint binds.
      def gate(identity:, command:, body:, pow:, method: 'POST', verb: nil) # rubocop:disable Metrics/ParameterLists -- WireController and the specs pass these six by name
        config = Kiosk.configuration
        policy = config.reputation_policy
        return :proceed if policy.nil?

        secret  = pow_secret!(config)
        factors = ReputationFactors.for(identity:, policy:)
        spec    = policy.challenge_for(identity: identity, verb: command.to_sym, factors: factors)
        return :proceed if spec.nil?

        fp = request_fingerprint(method: method, verb: verb || command, body: body)
        PowToll.new(spec: spec, fingerprint: fp, secret: secret, config: config)
               .collect!(pow).tap { TolledCalls.reset!(identity.user_id) if factors.calls_since_proof }
      end

      def pow_secret!(config)
        unless defined?(::Kiosk::Reputation::Challenge)
          raise Errors::ConfigurationError,
                'Kiosk::Server: reputation_policy is set but kiosk-reputation is not loaded. ' \
                "Add `require 'kiosk/reputation'` (and `gem 'kiosk-reputation'`) to your app."
        end

        secret = config.pow_secret
        return secret unless secret.nil? || secret.to_s.strip.empty?

        raise Errors::ConfigurationError,
              'Kiosk::Server: reputation_policy is set but pow_secret is nil or empty. ' \
              "Set: Kiosk.configure { |c| c.pow_secret = ENV.fetch('KIOSK_POW_SECRET') }"
      end

      # One proof, a JSON array, repeated header lines (Rack joins them with
      # "\n") or comma-joined ones; nil when absent.
      def proofs_from_header(raw)
        return nil if raw.nil?

        proofs = raw.split("\n").map(&:strip).reject(&:empty?).flat_map { |value| proofs_in(value) }
        proofs.empty? ? nil : proofs
      rescue JSON::ParserError
        raise Errors::BadRequest.new('malformed Kiosk-PoW header', hint: POW_HEADER_HINT)
      end

      def proofs_in(value)
        Array(JSON.parse(value.start_with?('[') ? value : "[#{value}]", symbolize_names: true))
      end

      POW_HEADER_HINT =
        'the Kiosk-PoW header carries the proof(s) as raw minified JSON: a single ' \
        'proof {"challenge": <the challenge object from the 402, echoed verbatim>, ' \
        '"nonce": {"indices": […], "header_nonce"?}}, OR a JSON array of such ' \
        'proofs [{…},{…}]. Repeated Kiosk-PoW header lines (one proof each) also ' \
        'work. Solve every challenge issued in the pow_required 402 and echo it ' \
        'back verbatim.'

      # Unversioned: the server cannot know which skill cut its caller read.
      POW_SOLVER_URL = 'https://kiosk.tech/pow/solve.py'

      POW_INVALID_HINT =
        "solve with the reference solver at #{POW_SOLVER_URL} — " \
        'a hand-written Equihash solver will not match this verifier'.freeze

      def canonical_json(obj)
        case obj
        when Hash
          pairs = obj.sort_by { |k, _| k.to_s }
                     .map { |k, v| "#{JSON.generate(k.to_s)}:#{canonical_json(v)}" }
          "{#{pairs.join(',')}}"
        when Array
          "[#{obj.map { |v| canonical_json(v) }.join(',')}]"
        else
          JSON.generate(obj)
        end
      end
    end
  end
end
