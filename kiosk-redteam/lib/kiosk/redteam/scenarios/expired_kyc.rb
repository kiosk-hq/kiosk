# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Expired KYC: an attestation with exp in the past must be rejected.
      #
      # Attack:
      #   1. A registers.
      #   2. A submits profile.kyc_expired attestation (exp in the past).
      #   3. If the KYC call itself is rejected → BLOCKED.
      #   4. If the KYC call is accepted (lenient provider), A creates a
      #      resource, pays, and invokes gated_action.  BLOCKED iff denied.
      #
      # Skipped when: profile.requires_kyc is false, profile.kyc_expired is
      # nil, or profile.gated_action / create_owned / pay_for is nil.
      class ExpiredKyc < Scenario
        def initialize
          super(
            name:        "ExpiredKyc",
            category:    "kyc",
            description: "Expired KYC attestation must be rejected (at kyc or gated action)",
          )
        end

        def call(client, profile)
          return skip_verdict("requires_kyc is false")   unless profile.requires_kyc
          return skip_verdict("no kyc_expired callable") unless profile.kyc_expired
          return skip_verdict("no gated_action")         unless profile.gated_action
          return skip_verdict("no create_owned")         unless profile.create_owned
          return skip_verdict("no pay_for")              unless profile.pay_for

          a = register_principal(client, name: "redteam-expkyc-a", profile:)

          kyc_resp = client.kyc(a, attestation_jws: profile.kyc_expired.call(a.user_id))

          # A metered /kyc answers 402 BEFORE the attestation is examined, so the
          # expiry check never ran and neither did its opposite. This branch used
          # to count that 402 as "the expired attestation did not take effect"
          # (K-736); falling through instead would be worse still — the gated
          # action below would then be attacked by an un-attested principal, i.e.
          # MissingKyc running under this scenario's name.
          stall = payment_required_stall(kyc_resp, step: "the expired attestation this scenario submits to /kyc")
          return stall if stall

          # If the KYC endpoint itself rejected the expired attestation → BLOCKED.
          # Left permissive on purpose (K-728): this branch genuinely admits
          # several gates — a provider that verifies `exp` inside its attestation
          # verifier answers 403 forbidden, and one that treats a dead attestation
          # as a failed authentication answers 401. Both mean the same thing here
          # — the expired attestation did not take effect — and the scenario is
          # not trying to distinguish them.
          return verdict_from(kyc_resp, detail: "expired KYC was accepted by /kyc endpoint") if Kiosk::Redteam.blocked?(kyc_resp)

          # KYC call succeeded despite expiry — proceed to gated action to see
          # if the gate catches it there.
          owned_ref  = profile.create_owned.call(client, a)
          mandates   = profile.pay_for.call(client, a, owned_ref)
          pay_resp   = client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          # SETUP, not the attack: a refused payment leaves the gated action to
          # be refused by the payment gate, which this scenario would then read
          # as the expiry check (K-731).
          failure = setup_failure(
            pay_resp,
            step:    "the payment this scenario stages before the gated action",
            because: "The gated action would then be refused by the payment gate, and this " \
                     "scenario would credit that refusal to the KYC expiry check.",
          )
          return failure if failure

          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }
          resp       = client.run(a, name: profile.gated_action, **gated_args)

          # Admits several gates deliberately: an expired attestation may be
          # refused as kyc_required (403) or as unauthenticated (401) depending
          # on where the provider checks `exp`.
          verdict_from(resp, detail: "expired KYC accepted everywhere; gated action returned #{resp.status}")
        end
      end
    end
  end
end
