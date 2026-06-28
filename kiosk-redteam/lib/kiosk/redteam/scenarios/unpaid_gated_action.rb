# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Unpaid gated action: the pay gate must fire before the gated action.
      #
      # Attack:
      #   1. A registers (+ valid KYC if profile.requires_kyc).
      #   2. A creates an owned resource.
      #   3. A invokes profile.gated_action WITHOUT paying first.
      #   4. BLOCKED iff denied (HTTP 402/403 or domain error).
      #
      # Skipped when: profile.gated_action or profile.create_owned is nil.
      class UnpaidGatedAction < Scenario
        def initialize
          super(
            name:        "UnpaidGatedAction",
            category:    "payment",
            description: "Gated action without prior payment must be denied",
          )
        end

        def call(client, profile)
          return skip_verdict("no gated_action") unless profile.gated_action
          return skip_verdict("no create_owned") unless profile.create_owned

          a = register_principal(client, name: "redteam-uga-a", profile:)

          # KYC if the provider requires it (so the gated action is only
          # blocked by missing payment, not by missing KYC).
          submit_valid_kyc(client, a, profile) if profile.requires_kyc

          owned_ref = profile.create_owned.call(client, a)
          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }

          resp = client.run(a, name: profile.gated_action, **gated_args)

          verdict_from(resp, detail: "gated action succeeded without payment (HTTP #{resp.status})")
        end
      end
    end
  end
end
