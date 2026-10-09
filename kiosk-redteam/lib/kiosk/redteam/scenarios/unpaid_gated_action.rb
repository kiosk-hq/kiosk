# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # The gated action must be refused when nothing was paid for the resource.
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

          a = client.register!

          # A refused attestation would let the KYC gate answer in the payment gate's name.
          kyc_resp = (submit_valid_kyc(client, a, profile) if profile.requires_kyc)
          failure  = setup_failure(
            kyc_resp,
            step:    "the valid KYC attestation this scenario stages",
            because: "Without it the principal is also un-attested, so the refusal below " \
                     "would be the KYC gate rather than the payment gate under test.",
          )
          return failure if failure

          owned_ref = profile.create_owned.call(client, a)
          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }

          resp = client.run(a, name: profile.gated_action, **gated_args)

          # 401 or 403; a 402 cannot say which of its three codes answered.
          verdict_from(resp, detail: "gated action succeeded without payment (HTTP #{resp.status})")
        end
      end
    end
  end
end
