# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Submits a bad attestation to /kyc, then pays and runs the gated action.
      # The attack is refused when either step refuses it.
      module KycAttack
        private

        def kyc_attack(client, profile, attestation:, kind:, check:)
          a = client.register!
          kyc_resp = client.kyc(a, attestation_jws: attestation.call(a.user_id))
          kyc_refusal(kyc_resp, kind) || gated_after_kyc(client, profile, a, kind: kind, check: check)
        end

        # The verdict when /kyc already answered the attack, else nil.
        def kyc_refusal(kyc_resp, kind)
          # A metered /kyc answers 402 before the attestation is examined.
          stall = payment_required_stall(kyc_resp, step: "the #{kind} attestation this scenario submits to /kyc")
          return stall if stall
          # 401 and 403 both mean the attestation did not take effect.
          return verdict_from(kyc_resp, detail: "#{kind} KYC was accepted by /kyc endpoint") if Kiosk::Redteam.blocked?(kyc_resp)

          nil
        end

        def gated_after_kyc(client, profile, principal, kind:, check:)
          owned_ref = profile.create_owned.call(client, principal)
          failure = stage_payment(
            client, principal, profile, owned_ref,
            because: 'The gated action would then be refused by the payment gate, and this ' \
                     "scenario would credit that refusal to the #{check}."
          )
          return failure if failure

          resp = run_gated(client, principal, profile, owned_ref)
          verdict_from(resp, detail: "#{kind} KYC accepted everywhere; gated action returned #{resp.status}")
        end
      end
    end
  end
end
