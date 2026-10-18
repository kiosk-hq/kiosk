# frozen_string_literal: true

require 'kiosk/redteam/scenarios/kyc_attack'

module Kiosk
  module Redteam
    module Scenarios
      # An attestation from an untrusted issuer must be refused, at /kyc or at the gated action.
      class ForgedKyc < Scenario
        include KycAttack

        def initialize
          super(name: 'ForgedKyc')
        end

        def call(client, profile)
          skip_unless(profile, requires_kyc: 'requires_kyc is false', kyc_forged: 'no kyc_forged callable',
                               gated_action: 'no gated_action', create_owned: 'no create_owned',
                               pay_for: 'no pay_for') ||
            # kyc_required or unauthenticated, depending on the origin.
            kyc_attack(client, profile, attestation: profile.kyc_forged, kind: 'forged',
                                        check: 'KYC issuer check')
        end
      end
    end
  end
end
