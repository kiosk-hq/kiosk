# frozen_string_literal: true

require 'kiosk/redteam/scenarios/kyc_attack'

module Kiosk
  module Redteam
    module Scenarios
      # An attestation whose exp is past must be refused, either at /kyc or at the gated action.
      class ExpiredKyc < Scenario
        include KycAttack

        def initialize
          super(
            name: 'ExpiredKyc',
            category: 'kyc',
            description: 'Expired KYC attestation must be rejected (at kyc or gated action)',
          )
        end

        def call(client, profile)
          skip_unless(profile, requires_kyc: 'requires_kyc is false', kyc_expired: 'no kyc_expired callable',
                               gated_action: 'no gated_action', create_owned: 'no create_owned',
                               pay_for: 'no pay_for') ||
            # kyc_required or unauthenticated, depending on where the origin checks exp.
            kyc_attack(client, profile, attestation: profile.kyc_expired, kind: 'expired',
                                        check: 'KYC expiry check')
        end
      end
    end
  end
end
