# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # The gated action must be refused, after payment, when no KYC was submitted.
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

          a = client.register!
          # No KYC call here — that is the attack.

          owned_ref  = profile.create_owned.call(client, a)
          mandates   = profile.pay_for.call(client, a, owned_ref)
          pay_resp   = client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          failure = setup_failure(
            pay_resp,
            step:    "the payment this scenario stages before the gated action",
            because: "The gated action would then be refused by the payment gate, and this " \
                     "scenario would credit that refusal to the KYC gate it is meant to prove.",
          )
          return failure if failure

          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }
          resp       = client.run(a, name: profile.gated_action, **gated_args)

          # 403 kyc_required, or 401 from an origin that treats the principal as unauthenticated.
          verdict_from(resp, detail: "gated action succeeded without KYC (HTTP #{resp.status})")
        end
      end
    end
  end
end
