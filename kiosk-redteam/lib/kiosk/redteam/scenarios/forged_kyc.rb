# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # An attestation from an untrusted issuer must be refused, at /kyc or at the gated action.
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

          a = client.register!

          kyc_resp = client.kyc(a, attestation_jws: profile.kyc_forged.call(a.user_id))

          # A metered /kyc answers 402 before the issuer or signature is examined.
          stall = payment_required_stall(kyc_resp, step: "the forged attestation this scenario submits to /kyc")
          return stall if stall

          # 401 and 403 both mean the forged attestation did not take effect.
          return verdict_from(kyc_resp, detail: "forged KYC was accepted by /kyc endpoint") if Kiosk::Redteam.blocked?(kyc_resp)

          owned_ref  = profile.create_owned.call(client, a)
          mandates   = profile.pay_for.call(client, a, owned_ref)
          pay_resp   = client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          failure = setup_failure(
            pay_resp,
            step:    "the payment this scenario stages before the gated action",
            because: "The gated action would then be refused by the payment gate, and this " \
                     "scenario would credit that refusal to the KYC issuer check.",
          )
          return failure if failure

          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }
          resp       = client.run(a, name: profile.gated_action, **gated_args)

          # kyc_required or unauthenticated, depending on the origin.
          verdict_from(resp, detail: "forged KYC accepted everywhere; gated action returned #{resp.status}")
        end
      end
    end
  end
end
