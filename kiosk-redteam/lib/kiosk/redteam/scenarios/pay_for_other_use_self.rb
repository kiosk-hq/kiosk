# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Pay-for-A, use-as-B (C2) — the headline Phase-1 I-1 scenario.
      #
      # Attack:
      #   1. A registers (no KYC needed — A just creates a resource).
      #   2. B registers + KYC (if required).
      #   3. A creates an owned resource → owned_ref_A.
      #   4. B builds + pays a cart mandate referencing owned_ref_A but with
      #      B's own user_id/agent_id (mandate is legitimately B's, so payment
      #      is expected to succeed — the cart simply references A's resource).
      #   5. B invokes profile.gated_action on owned_ref_A.
      #   6. BLOCKED iff denied — the ownership gate must check that the
      #      authenticated principal owns the resource, not just that payment
      #      exists for it.
      #
      # This is Gate-1: "who owns this resource?" checked at gated_action time,
      # not at pay time.
      #
      # Skipped when: profile.gated_action, profile.create_owned, or
      # profile.pay_for is nil.
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

          a = register_principal(client, name: "redteam-c2-a", profile:)
          b = register_principal(client, name: "redteam-c2-b", profile:)

          # B KYC'd (so the gated action isn't blocked by missing KYC; we
          # want to test the ownership gate specifically).
          submit_valid_kyc(client, b, profile) if profile.requires_kyc

          # A creates the resource (A owns it).
          owned_ref_a = profile.create_owned.call(client, a)

          # B builds mandates with B's own identity but referencing A's resource.
          mandates = profile.pay_for.call(client, b, owned_ref_a)
          pay_resp = client.pay(b, intent: mandates[:intent], cart: mandates[:cart])

          # Payment may or may not succeed depending on whether the provider
          # validates resource ownership at pay time.  If payment is already
          # rejected, the gate fires early — also a valid block.
          if Kiosk::Redteam.blocked?(pay_resp)
            return Verdict.new(
              blocked: true,
              status:  pay_resp.status,
              detail:  "blocked at pay step (early ownership check)",
            )
          end

          # B tries to invoke the gated action on A's resource.
          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref_a) : { id: owned_ref_a[:id] }
          resp       = client.run(b, name: profile.gated_action, **gated_args)

          verdict_from(resp, detail: "B used A's resource after paying for it (C2 breach, HTTP #{resp.status})")
        end
      end
    end
  end
end
