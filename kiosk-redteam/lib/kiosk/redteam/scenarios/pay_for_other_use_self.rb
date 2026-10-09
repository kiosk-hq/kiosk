# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B pays a mandate that references A's resource, then invokes the gated
      # action on it: the ownership gate must refuse at use time, not only at pay time.
      class PayForOtherUseSelf < Scenario
        def initialize
          super(
            name:        "PayForOtherUseSelf",
            category:    "authorization",
            description: "B pays for A's resource then tries to use it (C2 ownership gate)",
          )
        end

        def call(client, profile)
          return skip_verdict("no gated_action") unless profile.gated_action
          return skip_verdict("no create_owned") unless profile.create_owned
          return skip_verdict("no pay_for")      unless profile.pay_for

          a = client.register!
          b = client.register!

          kyc_resp = (submit_valid_kyc(client, b, profile) if profile.requires_kyc)
          failure  = setup_failure(
            kyc_resp,
            step:    "the valid KYC attestation this scenario stages for B",
            because: "B would otherwise be refused for want of KYC, and this scenario would " \
                     "credit that refusal to the ownership gate it exists to prove.",
          )
          return failure if failure

          owned_ref_a = profile.create_owned.call(client, a)

          mandates = profile.pay_for.call(client, b, owned_ref_a)
          pay_resp = client.pay(b, intent: mandates[:intent], cart: mandates[:cart])

          # Only 403 forbidden / rls_denied at pay time is the same ownership gate, moved earlier.
          if pay_resp.status == 403 && %w[forbidden rls_denied].include?(error_code(pay_resp))
            return Verdict.new(
              blocked: true,
              skipped: false,
              status:  pay_resp.status,
              detail:  "blocked at pay step (early ownership check)",
            )
          end

          # Any other non-200 at pay time means the attack was never attempted.
          failure = setup_failure(
            pay_resp,
            step:    "B's payment for A's resource",
            because: "A 403 forbidden/rls_denied here would be the ownership gate firing early " \
                     "and is scored as a pass; any other refusal (a 402 decline, a 401 expired " \
                     "token) simply means the attack below was never attempted.",
          )
          return failure if failure

          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref_a) : { id: owned_ref_a[:id] }
          resp       = client.run(b, name: profile.gated_action, **gated_args)

          # Only the ownership gate counts: B did pay, so a 402 or kyc_required is another gate.
          verdict_from(
            resp,
            expect:      403,
            expect_code: %w[forbidden rls_denied],
            detail:      "B used A's resource after paying for it (C2 breach, HTTP #{resp.status})",
          )
        end
      end
    end
  end
end
