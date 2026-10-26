# frozen_string_literal: true

module Kiosk
  module Server
    # Optional proof-of-work toll on the auth requests that come before a
    # token: `POST /oauth/register`, the link-code claim `POST /auth/claim`, and
    # the first token poll of each device code. It runs before any lookup, so
    # the answer never tells a caller whether a key or a code exists. It sets
    # the cost of each request, not a rate. The shipped deploy has no edge rate
    # limit (deploy/README.md "Edge rate-limit").
    module AuthToll
      module_function

      def on?(config = Kiosk.configuration) = config.registration_pow_count.to_i.positive?

      # `verb` and `body` make the fingerprint, so a proof clears the toll of this request only.
      def gate(verb:, body:, pow:, config: Kiosk.configuration)
        return unless on?(config)

        secret = secret!(config)
        spec = { alg: 'equihash', params: ::Kiosk::Pow::Equihash.params, count: config.registration_pow_count.to_i }
        fp = PowGate.request_fingerprint(method: 'POST', verb: verb, body: body)

        PowToll.new(spec: spec, fingerprint: fp, secret: secret, config: config).collect!(pow)
        nil
      end

      def secret!(config)
        unless defined?(::Kiosk::Reputation::Challenge) && defined?(::Kiosk::Pow::Equihash.params)
          raise Errors::ConfigurationError,
                'registration_pow_count > 0 requires kiosk-reputation and kiosk-pow-equihash. ' \
                'Add both gems (and `require` them) to your app.'
        end

        secret = config.pow_secret
        return secret unless secret.nil? || secret.to_s.strip.empty?

        raise Errors::ConfigurationError,
              'registration_pow_count > 0 requires pow_secret. ' \
              "Set: Kiosk.configure { |c| c.pow_secret = ENV.fetch('KIOSK_POW_SECRET') }"
      end
    end
  end
end
