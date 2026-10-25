# frozen_string_literal: true

module Kiosk
  module Redteam
    # Setup steps the scenarios share. Mixed into Scenario as private methods.
    module Staging
      private

      def submit_valid_kyc(client, principal, profile)
        return nil unless profile.kyc_valid

        client.kyc(principal, attestation_jws: profile.kyc_valid.call(principal.user_id))
      end

      # Submits a valid attestation when the profile requires KYC. Answers a setup-failure verdict or nil.
      def stage_kyc(client, principal, profile, step:, because:)
        kyc_resp = (submit_valid_kyc(client, principal, profile) if profile.requires_kyc)
        setup_failure(kyc_resp, step: step, because: because)
      end

      # Pays for +owned_ref+ as +payer+ and answers the pay response.
      def pay_for_owned(client, payer, profile, owned_ref)
        client.pay(payer, profile.pay_for.call(client, payer, owned_ref))
      end

      # The claims of +checkout_jwt+ with +changes+, signed again by a key the operator never held.
      def tampered_checkout(checkout_jwt, **changes)
        claims, header = JWT.decode(checkout_jwt, nil, false)
        JWT.encode(claims.merge(changes.transform_keys(&:to_s)), OpenSSL::PKey.generate_key('ED25519'), 'EdDSA',
                   header.slice('kid', 'typ'))
      end

      # +checkout_jwt+ with each priced line +by+ cents cheaper and the total to match, so the
      # lines still sum to the total. The lines keep every other member the operator signed.
      def underpriced_checkout(checkout_jwt, by:)
        paid, *priced = JWT.decode(checkout_jwt, nil, false).first.fetch('line_items')
        priced = priced.map { |line| line.merge('price_cents' => line.fetch('price_cents') - by) }
        tampered_checkout(checkout_jwt, line_items: [paid, *priced],
                                        total_amount_cents: priced.sum { |line| line.fetch('qty') * line.fetch('price_cents') })
      end

      # The two mandates for +checkout_jwt+, with the payment mandate's fields changed and signed again.
      def mandates_with_payment(principal, checkout_jwt, **changes)
        mandates = Kiosk::TestHelpers::Mandate.pay(principal.key, checkout_jwt)
        payment = Kiosk::TestHelpers::Mandate.content(mandates[:payment]).merge(changes.transform_keys(&:to_s))
        mandates.merge(payment: Kiosk::TestHelpers::Mandate.sign(principal.key, payment))
      end

      # Pays for +owned_ref+ before a gated action. Answers a setup-failure verdict or nil.
      def stage_payment(client, principal, profile, owned_ref, because:)
        setup_failure(pay_for_owned(client, principal, profile, owned_ref),
                      step: 'the payment this scenario stages before the gated action', because: because)
      end

      def run_gated(client, principal, profile, owned_ref)
        gated_args = profile.gated_args ? profile.gated_args.call(owned_ref) : { id: owned_ref[:id] }
        client.run(principal, name: profile.gated_action, **gated_args)
      end

      # A query answers a bare Array (§8.2); any other body reads as no rows.
      def rows_from(response)
        body = response.body
        body.is_a?(Array) ? body : []
      end
    end
  end
end
