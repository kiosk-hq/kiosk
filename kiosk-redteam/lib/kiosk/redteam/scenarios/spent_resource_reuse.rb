# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # A consumed resource cannot be used again: the second gated_action call
      # must be refused. Skipped when gated_action_consumes is false.
      class SpentResourceReuse < Scenario
        KYC_BECAUSE = 'The first, legitimate use below would then fail for want of KYC, and ' \
                      'the re-use this scenario tests would never be reached.'

        def initialize
          super(name: 'SpentResourceReuse')
        end

        def call(client, profile)
          skip_unless(profile, gated_action: 'no gated_action', create_owned: 'no create_owned',
                               pay_for: 'no pay_for', gated_action_consumes: 'gated_action spends nothing') ||
            attack(client, profile)
        end

        private

        def attack(client, profile)
          a = client.register!
          failure = stage_kyc(client, a, profile, step: 'the valid KYC attestation this scenario stages',
                                                  because: KYC_BECAUSE)
          return failure if failure

          owned_ref = profile.create_owned.call(client, a)
          pay_for_owned(client, a, profile, owned_ref)
          first_use_failure(run_gated(client, a, profile, owned_ref)) || reuse(client, a, profile, owned_ref)
        end

        def first_use_failure(first_resp)
          return nil if first_resp.status == 200

          breach_verdict(first_resp.status, "first gated_action failed (#{first_resp.status}); cannot test C3")
        end

        # Only the resource-state gate's 403 counts: A paid, and the first use succeeded.
        def reuse(client, principal, profile, owned_ref)
          resp = run_gated(client, principal, profile, owned_ref)
          verdict_from(resp, expect: 403, expect_code: %w[forbidden rls_denied],
                             detail: "spent resource re-activated (HTTP #{resp.status})")
        end
      end
    end
  end
end
