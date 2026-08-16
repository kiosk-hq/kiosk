# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Forged KYC: an attestation signed by an untrusted issuer must be rejected.
      #
      # Attack:
      #   1. A registers.
      #   2. A submits profile.kyc_forged attestation (wrong issuer / bad sig).
      #   3. If the KYC call itself is rejected → BLOCKED.
      #   4. If accepted, A creates a resource, pays, invokes gated_action.
      #      BLOCKED iff denied at that point.
      #
      # Skipped when: profile.requires_kyc is false, profile.kyc_forged is
      # nil, or profile.gated_action / create_owned / pay_for is nil.
      class ForgedKyc < Scenario
        def initialize
          super(
            name:        "ForgedKyc",
            category:    "kyc",
            description: "KYC attestation with wrong issuer/signature must be rejected",
          )
        end

        def call(client, profile)
          return skip_verdict("requires_kyc is false")   unless profile.requires_kyc
          return skip_verdict("no kyc_forged callable")  unless profile.kyc_forged
          return skip_verdict("no gated_action")         unless profile.gated_action
          return skip_verdict("no create_owned")         unless profile.create_owned
          return skip_verdict("no pay_for")              unless profile.pay_for

          a = register_principal(client, name: "redteam-fkyc-a", profile:)

          kyc_resp = client.kyc(a, attestation_jws: profile.kyc_forged.call(a.user_id))

          # A metered /kyc answers 402 BEFORE the issuer/signature is examined,
          # so the forgery was neither caught nor accepted. This branch used to
          # count that 402 as "the forged attestation did not take effect"
          # (K-736); falling through instead would attack the gated action with
          # an un-attested principal, i.e. MissingKyc under this scenario's name.
          stall = payment_required_stall(kyc_resp, step: "the forged attestation this scenario submits to /kyc")
          return stall if stall

          # Left permissive on purpose (K-728): this branch genuinely admits
          # several gates — an untrusted issuer is rejected as 403 forbidden by
          # a verifier that checks `iss`, and as 401 by one that treats an
          # unverifiable signature as a failed authentication. Both mean the
          # forged attestation did not take effect, which is all this claims.
          return verdict_from(kyc_resp, detail: "forged KYC was accepted by /kyc endpoint") if Kiosk::Redteam.blocked?(kyc_resp)

          owned_ref  = profile.create_owned.call(client, a)
          mandates   = profile.pay_for.call(client, a, owned_ref)
          pay_resp   = client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          # SETUP, not the attack: a refused payment leaves the gated action to
          # be refused by the payment gate, which this scenario would then read
          # as the issuer/signature check (K-731).
          failure = setup_failure(
            pay_resp,
            step:    "the payment this scenario stages before the gated action",
            because: "The gated action would then be refused by the payment gate, and this " \
                     "scenario would credit that refusal to the KYC issuer check.",
          )
          return failure if failure

          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }
          resp       = client.run(a, name: profile.gated_action, **gated_args)

          # Admits several gates deliberately: an untrusted issuer may be
          # refused as kyc_required (403) or as unauthenticated (401).
          verdict_from(resp, detail: "forged KYC accepted everywhere; gated action returned #{resp.status}")
        end
      end
    end
  end
end
