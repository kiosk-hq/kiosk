# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Unpaid gated action: the pay gate must fire before the gated action.
      #
      # Attack:
      #   1. A registers (+ valid KYC if profile.requires_kyc).
      #   2. A creates an owned resource.
      #   3. A invokes profile.gated_action WITHOUT paying first.
      #   4. BLOCKED iff denied (HTTP 401/403 or a recognised denial code).
      #
      # Skipped when: profile.gated_action or profile.create_owned is nil.
      class UnpaidGatedAction < Scenario
        def initialize
          super(
            name:        "UnpaidGatedAction",
            category:    "payment",
            description: "Gated action without prior payment must be denied",
          )
        end

        def call(client, profile)
          return skip_verdict("no gated_action") unless profile.gated_action
          return skip_verdict("no create_owned") unless profile.create_owned

          a = register_principal(client, name: "redteam-uga-a", profile:)

          # KYC if the provider requires it (so the gated action is only
          # blocked by missing payment, not by missing KYC).  That result used
          # to be discarded (K-731) — and it is the ONLY thing separating this
          # scenario from MissingKyc: if the attestation was not accepted, the
          # refusal below is the KYC gate wearing the payment gate's name.
          kyc_resp = (submit_valid_kyc(client, a, profile) if profile.requires_kyc)
          failure  = setup_failure(
            kyc_resp,
            step:    "the valid KYC attestation this scenario stages",
            because: "Without it the principal is also un-attested, so the refusal below " \
                     "would be the KYC gate rather than the payment gate under test.",
          )
          return failure if failure

          owned_ref = profile.create_owned.call(client, a)
          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }

          resp = client.run(a, name: profile.gated_action, **gated_args)

          # Admits several gates deliberately: an ownership-and-settlement gate
          # that finds no settlement row answers 403, and a provider that treats
          # an unsettled principal as unauthenticated answers 401. The KYC
          # confusion is ruled out by the setup assertion above.
          #
          # A 402 no longer counts (K-736). It reads like the payment gate, but
          # the status alone cannot say WHICH of pow_required (a toll — the
          # action never ran) / payment_setup_required (no card on file) /
          # payment_failed (the rail declined after every gate said yes) came
          # back, and only the last two are about paying for THIS resource.
          # Measured: all three consuming demos answer 403 here, so nothing
          # moves; a provider whose pay gate really does answer 402 must name
          # its code with expect_code: rather than have this scenario guess.
          verdict_from(resp, detail: "gated action succeeded without payment (HTTP #{resp.status})")
        end
      end
    end
  end
end
