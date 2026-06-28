# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Missing KYC: the KYC gate must fire before the gated action.
      #
      # Attack:
      #   1. A registers (NO KYC submitted).
      #   2. A creates an owned resource and pays.
      #   3. A invokes profile.gated_action WITHOUT a prior KYC call.
      #   4. BLOCKED iff denied (HTTP 403 or domain error).
      #
      # Skipped when: profile.requires_kyc is false, or profile.gated_action /
      # profile.create_owned / profile.pay_for is nil.
      class MissingKyc < Scenario
        def initialize
          super(
            name:        "MissingKyc",
            category:    "kyc",
            description: "Gated action without KYC (but after payment) must be denied",
          )
        end

        def call(client, profile)
          return skip_verdict("requires_kyc is false")   unless profile.requires_kyc
          return skip_verdict("no gated_action")         unless profile.gated_action
          return skip_verdict("no create_owned")         unless profile.create_owned
          return skip_verdict("no pay_for")              unless profile.pay_for

          a = register_principal(client, name: "redteam-mkyc-a", profile:)
          # No KYC call here — that is the attack.

          owned_ref  = profile.create_owned.call(client, a)
          mandates   = profile.pay_for.call(client, a, owned_ref)
          client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }
          resp       = client.run(a, name: profile.gated_action, **gated_args)

          verdict_from(resp, detail: "gated action succeeded without KYC (HTTP #{resp.status})")
        end
      end
    end
  end
end
