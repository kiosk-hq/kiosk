# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B pays a mandate that references A's resource, then invokes the gated
      # action on it: the ownership gate must refuse at use time, not only at pay time.
      class PayForOtherUseSelf < Scenario
        KYC_BECAUSE = 'B would otherwise be refused for want of KYC, and this scenario would ' \
                      'credit that refusal to the ownership gate it exists to prove.'

        def initialize
          super(
            name: 'PayForOtherUseSelf',
            category: 'authorization',
            description: "B pays for A's resource then tries to use it (C2 ownership gate)",
          )
        end

        def call(client, profile)
          skip_unless(profile, gated_action: 'no gated_action', create_owned: 'no create_owned',
                               pay_for: 'no pay_for') ||
            attack(client, profile)
        end

        private

        def attack(client, profile)
          a = client.register!
          b = client.register!
          failure = stage_kyc(client, b, profile, step: 'the valid KYC attestation this scenario stages for B',
                                                  because: KYC_BECAUSE)
          return failure if failure

          owned_ref_a = profile.create_owned.call(client, a)
          pay_verdict(pay_for_owned(client, b, profile, owned_ref_a)) || use(client, b, profile, owned_ref_a)
        end

        # The verdict when B's payment already decided the attack, else nil.
        def pay_verdict(pay_resp)
          # Only 403 forbidden / rls_denied at pay time is the same ownership gate, moved earlier.
          return blocked_verdict(pay_resp.status, 'blocked at pay step (early ownership check)') if pay_resp.status == 403 && %w[forbidden rls_denied].include?(error_code(pay_resp))

          # Any other non-200 at pay time means the attack was never attempted.
          setup_failure(
            pay_resp,
            step: "B's payment for A's resource",
            because: 'A 403 forbidden/rls_denied here would be the ownership gate firing early ' \
                     'and is scored as a pass; any other refusal (a 402 decline, a 401 expired ' \
                     'token) simply means the attack below was never attempted.'
          )
        end

        # Only the ownership gate counts: B did pay, so a 402 or kyc_required is another gate.
        def use(client, principal, profile, owned_ref)
          resp = run_gated(client, principal, profile, owned_ref)
          verdict_from(resp, expect: 403, expect_code: %w[forbidden rls_denied],
                             detail: "B used A's resource after paying for it (C2 breach, HTTP #{resp.status})")
        end
      end
    end
  end
end
