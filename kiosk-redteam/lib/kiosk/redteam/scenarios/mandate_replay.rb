# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B re-submits A's already-used mandate JWS under B's token: must be refused.
      class MandateReplay < Scenario
        def initialize
          super(name: 'MandateReplay')
        end

        def call(client, profile)
          skip_unless(profile, pay_for: 'no pay_for', create_owned: 'no create_owned') ||
            attack(client, profile)
        end

        private

        def attack(client, profile)
          a = client.register!
          b = client.register!
          mandates = profile.pay_for.call(client, a, profile.create_owned.call(client, a))
          signed = signed_mandates(client, a, mandates)
          client.pay(a, intent: mandates[:intent], cart: mandates[:cart])
          resp = client.pay_raw(b, **signed)

          # Only 403: a 402 decline would mean the replay was never verified.
          verdict_from(resp, expect: 403, expect_code: %w[forbidden rls_denied],
                             detail: "mandate replay accepted under B's token (HTTP #{resp.status})")
        end

        def signed_mandates(client, principal, mandates)
          {
            intent_jws: client.sign_mandate(principal, mandates[:intent]),
            cart_jws: client.sign_mandate(principal, mandates[:cart]),
            payment_jws: client.sign_mandate(principal, client.payment_mandate(principal, cart: mandates[:cart]))
          }
        end
      end
    end
  end
end
