# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B pays, under its own token and key, mandates claiming A's identity: must be refused.
      class MandatePrincipalSwap < Scenario
        def initialize
          super(name: 'MandatePrincipalSwap')
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
          resp = client.pay(b, intent: mandates[:intent], cart: mandates[:cart])

          # Only 403: a 402 or 401 means the swap was never examined.
          verdict_from(resp, expect: 403, expect_code: %w[forbidden rls_denied],
                             detail: "principal-swap mandate accepted (HTTP #{resp.status})")
        end
      end
    end
  end
end
