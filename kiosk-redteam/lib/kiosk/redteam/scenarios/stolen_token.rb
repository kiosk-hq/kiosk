# frozen_string_literal: true

require 'openssl'

module Kiosk
  module Redteam
    module Scenarios
      # A copied access token without its private key buys no request (RFC 9449):
      # sent as a bearer token, or with a DPoP proof that another key signs, it
      # must be refused 401. The token with its own key is the control.
      class StolenToken < Scenario
        def initialize
          super(name: 'StolenToken')
        end

        def call(client, profile)
          verb = profile.per_user_query
          return skipped if verb.nil?

          victim  = client.register!
          control = client.query(victim, name: verb)
          return vacuous(control) unless control.status == 200

          accepted(attacks(client, victim, verb))
        end

        private

        def skipped = Verdict.new(blocked: false, skipped: true, status: 0, detail: TokenTampering::NO_ROUTED_VERB)

        # Blocked when every attack was refused 401; else the first accepted one.
        def accepted(attacks)
          label, resp = attacks.find { |_, answer| !verdict_from(answer, expect: 401).blocked }
          return blocked_verdict(401) unless resp

          breach_verdict(resp.status, "a stolen token was accepted #{label} (HTTP #{resp.status})")
        end

        def vacuous(control)
          breach_verdict(control.status, "the token with its own key was refused (HTTP #{control.status}): the refusals prove nothing")
        end

        def attacks(client, victim, verb)
          path = "/kiosk/#{verb}"
          { 'as a bearer token' => client.wire.get(path, {}, 'Authorization' => "Bearer #{victim.token}"),
            "with the thief's own key" => client.query(victim.with(rsa_key: OpenSSL::PKey::RSA.generate(2048)), name: verb) }
        end
      end
    end
  end
end
