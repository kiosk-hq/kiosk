# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B pays, under its own token and key, mandates claiming A's identity: must be refused.
      class MandatePrincipalSwap < Scenario
        def initialize
          super(
            name:        "MandatePrincipalSwap",
            category:    "mandate",
            description: "B signs a mandate carrying A's identity; provider must reject",
          )
        end

        def call(client, profile)
          return skip_verdict("no pay_for")      unless profile.pay_for
          return skip_verdict("no create_owned") unless profile.create_owned

          a = client.register!
          b = client.register!

          owned_ref = profile.create_owned.call(client, a)

          mandates = profile.pay_for.call(client, a, owned_ref)

          resp = client.pay(b, intent: mandates[:intent], cart: mandates[:cart])

          # Only 403: a 402 or 401 means the swap was never examined.
          verdict_from(
            resp,
            expect:      403,
            expect_code: %w[forbidden rls_denied],
            detail:      "principal-swap mandate accepted (HTTP #{resp.status})",
          )
        end
      end
    end
  end
end
