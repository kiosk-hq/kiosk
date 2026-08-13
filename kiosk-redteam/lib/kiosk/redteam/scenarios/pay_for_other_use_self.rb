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
      #   6. BLOCKED iff denied 403 forbidden/rls_denied — the ownership gate
      #      must check that the authenticated principal owns the resource, not
      #      just that payment exists for it.  Any OTHER refusal is a different
      #      gate answering, and this scenario names its own.
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
          # want to test the ownership gate specifically).  That result was
          # discarded — the K-731 class: an attestation the provider refused
          # leaves B un-attested, and the KYC gate then answers in the
          # ownership gate's name.
          kyc_resp = (submit_valid_kyc(client, b, profile) if profile.requires_kyc)
          failure  = setup_failure(
            kyc_resp,
            step:    "the valid KYC attestation this scenario stages for B",
            because: "B would otherwise be refused for want of KYC, and this scenario would " \
                     "credit that refusal to the ownership gate it exists to prove.",
          )
          return failure if failure

          # A creates the resource (A owns it).
          owned_ref_a = profile.create_owned.call(client, a)

          # B builds mandates with B's own identity but referencing A's resource.
          mandates = profile.pay_for.call(client, b, owned_ref_a)
          pay_resp = client.pay(b, intent: mandates[:intent], cart: mandates[:cart])

          # Payment may or may not succeed depending on whether the provider
          # validates resource ownership at pay time.  An EARLY OWNERSHIP CHECK
          # is a 403 forbidden / rls_denied — the same gate, moved to pay time.
          # It used to be any blocked? at all (K-732), so a 402 decline (the
          # card, the toll, no payment method on file) and a 401 expired token
          # were both reported as "blocked at pay step (early ownership check)"
          # and the attack was never attempted: the scenario returned a pass
          # naming a gate it had not reached.
          if pay_resp.status == 403 && %w[forbidden rls_denied].include?(error_code(pay_resp))
            return Verdict.new(
              blocked: true,
              skipped: false,
              status:  pay_resp.status,
              detail:  "blocked at pay step (early ownership check)",
            )
          end

          # Anything else non-200 at pay time is a setup failure, not the gate:
          # B never got to try A's resource, so nothing was proved either way.
          failure = setup_failure(
            pay_resp,
            step:    "B's payment for A's resource",
            because: "A 403 forbidden/rls_denied here would be the ownership gate firing early " \
                     "and is scored as a pass; any other refusal (a 402 decline, a 401 expired " \
                     "token) simply means the attack below was never attempted.",
          )
          return failure if failure

          # B tries to invoke the gated action on A's resource.
          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref_a) : { id: owned_ref_a[:id] }
          resp       = client.run(b, name: profile.gated_action, **gated_args)

          # This scenario knows which gate must fire: ownership, checked at use
          # time. A 402 here means the payment gate answered — but B DID pay, so
          # that is a different bug, not this one; a 403 kyc_required means the
          # KYC gate answered. Both used to score BLOCKED.
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
