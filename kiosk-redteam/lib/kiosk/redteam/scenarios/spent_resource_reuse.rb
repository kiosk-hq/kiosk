# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # A consumed resource cannot be used again: the second gated_action call
      # must be refused. Skipped when gated_action_consumes is false.
      class SpentResourceReuse < Scenario
        def initialize
          super(
            name:        "SpentResourceReuse",
            category:    "authorization",
            description: "A consumed resource must not be re-activated (C3)",
          )
        end

        def call(client, profile)
          return skip_verdict("no gated_action") unless profile.gated_action
          return skip_verdict("no create_owned") unless profile.create_owned
          return skip_verdict("no pay_for")      unless profile.pay_for
          return skip_verdict("gated_action spends nothing") unless profile.gated_action_consumes

          a = client.register!

          kyc_resp = (submit_valid_kyc(client, a, profile) if profile.requires_kyc)
          failure  = setup_failure(
            kyc_resp,
            step:    "the valid KYC attestation this scenario stages",
            because: "The first, legitimate use below would then fail for want of KYC, and " \
                     "the re-use this scenario tests would never be reached.",
          )
          return failure if failure

          owned_ref  = profile.create_owned.call(client, a)
          mandates   = profile.pay_for.call(client, a, owned_ref)
          client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }

          first_resp = client.run(a, name: profile.gated_action, **gated_args)
          unless first_resp.status == 200
            return Verdict.new(
              blocked: false,
              skipped: false,
              status:  first_resp.status,
              detail:  "first gated_action failed (#{first_resp.status}); cannot test C3",
            )
          end

          # Only the resource-state gate's 403 counts: A paid, and the first use succeeded.
          second_resp = client.run(a, name: profile.gated_action, **gated_args)

          verdict_from(
            second_resp,
            expect:      403,
            expect_code: %w[forbidden rls_denied],
            detail:      "spent resource re-activated (HTTP #{second_resp.status})",
          )
        end
      end
    end
  end
end
