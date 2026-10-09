# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B re-submits A's already-used mandate JWS under B's token: must be refused.
      class MandateReplay < Scenario
        def initialize
          super(
            name:        "MandateReplay",
            category:    "mandate",
            description: "Mandate non-transferability: B re-submits A's signed mandate JWS under B's token; provider must reject",
          )
        end

        def call(client, profile)
          return skip_verdict("no pay_for")      unless profile.pay_for
          return skip_verdict("no create_owned") unless profile.create_owned

          a = client.register!
          b = client.register!

          owned_ref = profile.create_owned.call(client, a)
          mandates  = profile.pay_for.call(client, a, owned_ref)

          intent_jws  = client.sign_mandate(a, mandates[:intent])
          cart_jws    = client.sign_mandate(a, mandates[:cart])
          payment     = client.payment_mandate(a, cart: mandates[:cart])
          payment_jws = client.sign_mandate(a, payment)

          client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          resp = client.pay_raw(b, intent_jws:, cart_jws:, payment_jws:)

          # Only 403: a 402 decline would mean the replay was never verified.
          verdict_from(
            resp,
            expect:      403,
            expect_code: %w[forbidden rls_denied],
            detail:      "mandate replay accepted under B's token (HTTP #{resp.status})",
          )
        end
      end
    end
  end
end
