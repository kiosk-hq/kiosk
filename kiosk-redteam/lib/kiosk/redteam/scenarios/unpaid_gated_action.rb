# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # The gated action must be refused when nothing was paid for the resource.
      class UnpaidGatedAction < Scenario
        def initialize
          super(
            name: 'UnpaidGatedAction',
            category: 'payment',
            description: 'Gated action without prior payment must be denied',
          )
        end

        def call(client, profile)
          skip_unless(profile, gated_action: 'no gated_action', create_owned: 'no create_owned') ||
            attack(client, profile)
        end

        private

        def attack(client, profile)
          a = client.register!
          # A refused attestation would let the KYC gate answer in the payment gate's name.
          failure = stage_kyc(
            client, a, profile,
            step: 'the valid KYC attestation this scenario stages',
            because: 'Without it the principal is also un-attested, so the refusal below ' \
                     'would be the KYC gate rather than the payment gate under test.'
          )
          return failure if failure

          resp = run_gated(client, a, profile, profile.create_owned.call(client, a))
          # 401 or 403; a 402 cannot say which of its three codes answered.
          verdict_from(resp, detail: "gated action succeeded without payment (HTTP #{resp.status})")
        end
      end
    end
  end
end
