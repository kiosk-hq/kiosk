# frozen_string_literal: true

module Kiosk
  module Server
    # Optional proof-of-work toll on `POST /auth/register`, bound to the key
    # being registered. It bounds the cost per request, not the rate: an edge
    # rate limit is required (deploy/README.md "Edge rate-limit").
    module RegistrationPow
      module_function

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
        fp = PowGate.request_fingerprint(method: "POST", verb: "auth/register",
                                         body: { public_key: public_key_pem })

        PowGate.enforce(
          spec:         spec,
          fingerprint:  fp,
          pow:          pow,
          secret:       secret,
          config:       config,
          on_bad_proof: -> {},
        )
        nil
      end
    end
  end
end
