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

          # If the KYC endpoint itself rejected the expired attestation → BLOCKED.
          return verdict_from(kyc_resp, detail: "expired KYC was accepted by /kyc endpoint") if Kiosk::Redteam.blocked?(kyc_resp)

          # KYC call succeeded despite expiry — proceed to gated action to see
          # if the gate catches it there.
          owned_ref  = profile.create_owned.call(client, a)
          mandates   = profile.pay_for.call(client, a, owned_ref)
          client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }
          resp       = client.run(a, name: profile.gated_action, **gated_args)

          verdict_from(resp, detail: "expired KYC accepted everywhere; gated action returned #{resp.status}")
        end
      end
    end
  end
end
