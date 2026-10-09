# frozen_string_literal: true

require "jwt"
require "openssl"
require "securerandom"
require "uri"
require "kiosk"
require "kiosk/test_helpers/wire"

module Kiosk
  module TestHelpers
    # Stands in for the operator's KYC provider for the length of each test, so
    # the test decides how an identity check ends.
    #
    #   include Kiosk::TestHelpers::Kyc
    #
    #   check = rider.requests_verification
    #   the_verification_service_confirms(check, age_over_18: true)
    module Kyc
      ISSUER   = "https://kyc.test.invalid"
      SETTINGS = %i[kyc_provider kyc_issuer kyc_public_key].freeze

      # Opens checks without a network and signs attestations for them.
      class Provider < Kiosk::KycProviders::Base
        Check = Data.define(:subject, :audience, :nonce, :callback_url)

        def self.key = @key ||= OpenSSL::PKey::RSA.generate(2048)

        def initialize
          super
          @checks = {}
        end

        def open_verification(subject:, audience:, callback_url:, **)
          request_id = SecureRandom.uuid
          @checks[request_id] = Check.new(subject:, audience:, nonce: SecureRandom.hex(16), callback_url:)
          { request_id:, nonce: @checks[request_id].nonce, verification_url: "#{ISSUER}/verify?request=#{request_id}" }
        end

        def check(request_id) = @checks.fetch(request_id) { raise ArgumentError, "no check #{request_id.inspect} was opened" }

        def attest(subject, audience, attributes)
          now = Time.now.to_i
          JWT.encode({ sub: subject.to_s, level: "verified", iss: ISSUER, aud: audience.to_s, attributes:,
                       iat: now, exp: now + 3600 }, self.class.key, "RS256")
        end
      end

      def self.included(base)
        before, after = base.respond_to?(:setup) ? %i[setup teardown] : %i[before after]
        base.public_send(before) { stand_in_for_kyc_provider }
        base.public_send(after) { restore_kyc_provider }
      end

      # The person behind `check` (the answer to request_kyc) passed it with these
      # attributes; the provider reports so through the callback the engine gave it.
      def the_verification_service_confirms(check, **attributes)
        request_id = check["request_id"]
        check  = @kyc_provider.check(request_id)
        jws    = @kyc_provider.attest(check.subject, check.audience, attributes)
        answer = Wire.new(base_url: URI.join(check.callback_url, "/").to_s)
                     .post(URI(check.callback_url).path, { request_id:, nonce: check.nonce, kyc_jws: jws })
        raise "the engine refused the KYC callback: #{answer.status} #{answer.body}" unless answer.status == 200

        jws
      end

      # An attestation the provider signed for this principal, as an assistant
      # submits it to `POST <endpoint>/agents/kyc`.
      def kyc_attestation(principal, **attributes)
        @kyc_provider.attest(principal.user_id, Kiosk.configuration.kyc_audience, attributes)
      end

      private

      def stand_in_for_kyc_provider
        config = Kiosk.configuration
        @replaced_kyc_settings = SETTINGS.to_h { [_1, config.public_send(_1)] }
        @kyc_provider = Provider.new
        config.kyc_provider   = @kyc_provider
        config.kyc_issuer     = ISSUER
        config.kyc_public_key = Provider.key.public_key
      end

      def restore_kyc_provider
        @replaced_kyc_settings&.each { |setting, value| Kiosk.configuration.public_send(:"#{setting}=", value) }
      end
    end
  end
end
