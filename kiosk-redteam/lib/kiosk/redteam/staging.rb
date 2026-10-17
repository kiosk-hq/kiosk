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
        mandates = profile.pay_for.call(client, payer, owned_ref)
        client.pay(payer, intent: mandates[:intent], cart: mandates[:cart])
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

      # A query answers a bare Array (§8.2); the `rows` envelope is read too so an
      # older origin's rows are not mistaken for an empty, unleaked list.
      def rows_from(response)
        body = response.body
        return body if body.is_a?(Array)
        return [] unless body.is_a?(Hash)

        rows = body['rows']
        rows.is_a?(Array) ? rows : []
      end
    end
  end
end
