# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Spent resource reuse (C3): a resource already consumed cannot be
      # activated again.
      #
      # Attack:
      #   1. A registers (+ valid KYC if required).
      #   2. A creates an owned resource, pays, and invokes gated_action once
      #      (expected to succeed — first use is legitimate).
      #   3. A invokes gated_action AGAIN on the same owned_ref.
      #   4. BLOCKED iff the second invocation is denied.
      #
      # Skipped when: profile.gated_action, profile.create_owned, or
      # profile.pay_for is nil.
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

          a = register_principal(client, name: "redteam-srr-a", profile:)
          submit_valid_kyc(client, a, profile) if profile.requires_kyc

          owned_ref  = profile.create_owned.call(client, a)
          mandates   = profile.pay_for.call(client, a, owned_ref)
          client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }

          # First use — expected to succeed (if it fails, provider has a bug
          # of a different kind; surface that clearly).
          first_resp = client.run(a, name: profile.gated_action, **gated_args)
          unless first_resp.status == 200
            return Verdict.new(
              blocked: false,
              status:  first_resp.status,
              detail:  "first gated_action failed (#{first_resp.status}); cannot test C3",
            )
          end

          # Second use — must be denied.
          second_resp = client.run(a, name: profile.gated_action, **gated_args)

          verdict_from(second_resp, detail: "spent resource re-activated (HTTP #{second_resp.status})")
        end
      end
    end
  end
end
