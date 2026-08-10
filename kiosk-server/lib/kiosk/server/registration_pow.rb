# frozen_string_literal: true

module Kiosk
  module Server
    # Equihash proof-of-work gate for agent registration (`POST /auth/register`).
    #
    # Pricing fresh identity minting is optional: when
    # `config.registration_pow_count` is 0 (the default) {.gate} returns
    # immediately. When > 0, registration must carry `count` valid Equihash
    # proofs, using the SAME challenge machinery as the reputation gate
    # ({PowGate} + `Kiosk::Reputation::Challenge`) — one PoW, one wire format.
    #
    # The challenges bind to the public key being registered (via the request
    # fingerprint), so a proof solved for one key cannot be reused for another,
    # and there is no principal yet, so a bad proof cannot be attributed to a
    # reputation record — it is simply rejected (403).
    #
    # == Anti-DoS: one challenge → at most one verify (K-540)
    #
    # This gate runs UNAUTHENTICATED, before PopVerifier, so a caller can take a
    # free 402 challenge and resubmit it with a valid HMAC sig but garbage
    # indices. {PowGate.enforce} claims the challenge id atomically BEFORE the
    # equihash verify (K-542), so a bad proof CONSUMES its challenge: a replay of
    # the same id is turned away with a fresh re-challenge (402) without a second
    # verify. One issued challenge therefore drives at most one hash-loop verify.
    # (The operator-side half — the edge rate-limit in deploy/Caddyfile — is
    # deploy config, out of this gem's scope.)
    module RegistrationPow
      module_function

      # @param public_key_pem [String]         the key being registered (normalised)
      # @param pow            [Array, nil] submitted proof(s) parsed from the
      #   `Kiosk-PoW` header (a flat list of `{challenge:, nonce:}`), or nil
      # @param config         [Kiosk::Configuration]
      # @return [void]
      # @raise  [Errors::PowRequired]       (402) when valid proofs are needed
      # @raise  [Errors::Forbidden]         (403) on a bad-faith proof
      # @raise  [Errors::ConfigurationError] when the gate is on but misconfigured
      def gate(public_key_pem:, pow:, config: Kiosk.configuration)
        count = config.registration_pow_count.to_i
        return if count <= 0

        unless defined?(::Kiosk::Reputation) && defined?(::Kiosk::Pow::Equihash)
          raise Errors::ConfigurationError,
            "registration_pow_count > 0 requires kiosk-reputation and kiosk-pow-equihash. " \
            "Add both gems (and `require` them) to your app."
        end

        secret = config.pow_secret
        if secret.nil? || secret.to_s.strip.empty?
          raise Errors::ConfigurationError,
            "registration_pow_count > 0 requires pow_secret. " \
            "Set: Kiosk.configure { |c| c.pow_secret = ENV.fetch('KIOSK_POW_SECRET') }"
        end

        params = config.registration_pow_params || ::Kiosk::Pow::Equihash.params
        spec   = { alg: "equihash", params: params, count: count }
        # Bind the challenges to THIS public key — a proof for one key is useless
        # for another. `pow` is excluded from the fingerprint (added on retry).
        fp = PowGate.request_fingerprint(command: "auth/register", body: { public_key: public_key_pem })

        PowGate.enforce(
          spec:         spec,
          fingerprint:  fp,
          pow:          pow,
          secret:       secret,
          config:       config,
          on_bad_proof: -> {}, # no principal yet — nothing to penalise
        )
        nil
      end
    end
  end
end
