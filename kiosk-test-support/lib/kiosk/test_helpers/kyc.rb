# frozen_string_literal: true

require 'jwt'
require 'openssl'
require 'securerandom'
require 'uri'
require 'kiosk'
require 'kiosk/test_helpers/wire'

module Kiosk
  module TestHelpers
    # Stands in for the operator's KYC provider for the length of each test, so
    # the test decides how an identity check ends.
    #
    #   include Kiosk::TestHelpers::Kyc
    #
    #   rider.requests_verification
    #   the_verification_service_confirms(rider, age_over_18: true)
    module Kyc
      ISSUER = 'https://kyc.test.invalid'

      # Opens checks without a network and signs attestations for them, for
      # the audience of the provider it stands in for.
      class Provider < Kiosk::KycProviders::Base
        Check = Data.define(:subject, :audience, :nonce, :callback_url)

        def self.key = @key ||= OpenSSL::PKey.generate_key('ED25519')

        def initialize(audience:)
          super(issuer: ISSUER, public_key: self.class.key, audience:)
          @checks = {}
        end

        def opens_verifications? = true

        def open_verification(subject:, callback_url:, **)
          request_id = SecureRandom.uuid
          @checks[request_id] = Check.new(subject:, audience:, nonce: SecureRandom.hex(16), callback_url:)
          { request_id:, nonce: @checks[request_id].nonce, verification_url: "#{ISSUER}/verify?request=#{request_id}" }
        end

        def latest_check_for(subject)
          @checks.select { |_, check| check.subject == subject.to_s }.keys.last or
            raise ArgumentError, "no check was opened for #{subject.inspect}"
        end

        def check(request_id) = @checks.fetch(request_id)

        def attest(subject, audience, attributes)
          now = Time.now.to_i
          JWT.encode({ sub: subject.to_s, level: 'verified', iss: ISSUER, aud: audience.to_s, attributes:,
                       iat: now, exp: now + 3600 }, self.class.key, 'EdDSA')
        end
      end

      def self.included(base)
        before, after = base.respond_to?(:setup) ? %i[setup teardown] : %i[before after]
        base.public_send(before) { stand_in_for_kyc_provider }
        base.public_send(after) { restore_kyc_provider }
      end

      # The person behind `customer` passed the check they asked for last, with
      # these attributes; the provider reports so through the callback the engine gave it.
      def the_verification_service_confirms(customer, **attributes)
        request_id = @kyc_provider.latest_check_for(customer.principal.user_id)
        check  = @kyc_provider.check(request_id)
        jws    = @kyc_provider.attest(check.subject, check.audience, attributes)
        answer = deliver_callback(check, { request_id:, nonce: check.nonce, kyc_jws: jws })
        raise "the engine refused the KYC callback: #{answer.status} #{answer.body}" unless answer.status == 200

        jws
      end

      # An attestation the provider signed for this principal, as an assistant
      # submits it to `POST <endpoint>/agents/kyc`.
      def kyc_attestation(principal, **attributes)
        @kyc_provider.attest(principal.user_id, @kyc_provider.audience, attributes)
      end

      private

      def deliver_callback(check, body)
        Wire.new(base_url: URI.join(check.callback_url, '/').to_s).post(URI(check.callback_url).path, body)
      end

      def stand_in_for_kyc_provider
        config = Kiosk.configuration
        @replaced_kyc_provider = config.kyc_provider
        @kyc_provider = Provider.new(audience: @replaced_kyc_provider&.audience)
        config.kyc_provider = @kyc_provider
      end

      def restore_kyc_provider
        Kiosk.configuration.kyc_provider = @replaced_kyc_provider if @kyc_provider
      end
    end
  end
end
