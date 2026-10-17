# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # The gated action must be refused, after payment, when no KYC was submitted.
      class MissingKyc < Scenario
        def initialize
          super(
            name: 'MissingKyc',
            category: 'kyc',
            description: 'Gated action without KYC (but after payment) must be denied',
          )
        end

        def call(client, profile)
          skip_unless(profile, requires_kyc: 'requires_kyc is false', gated_action: 'no gated_action',
                               create_owned: 'no create_owned', pay_for: 'no pay_for') ||
            attack(client, profile)
        end

        private

        def attack(client, profile)
          a = client.register!
          # No KYC call here — that is the attack.
          owned_ref = profile.create_owned.call(client, a)
          failure = stage_payment(
            client, a, profile, owned_ref,
            because: 'The gated action would then be refused by the payment gate, and this ' \
                     'scenario would credit that refusal to the KYC gate it is meant to prove.'
          )
          return failure if failure

          resp = run_gated(client, a, profile, owned_ref)
          # 403 kyc_required, or 401 from an origin that treats the principal as unauthenticated.
          verdict_from(resp, detail: "gated action succeeded without KYC (HTTP #{resp.status})")
        end
      end
    end
  end
end
