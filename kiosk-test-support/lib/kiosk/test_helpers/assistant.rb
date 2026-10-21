# frozen_string_literal: true

require 'json'
require 'openssl'
require 'securerandom'
require 'uri'
require 'jwt'
require 'kiosk/test_helpers/wire'
require 'kiosk/test_helpers/mandate'
require 'kiosk/test_helpers/assistant/events'

module Kiosk
  module TestHelpers
    # An assistant on the wire: registers, then queries, runs and pays as the
    # principal it registered, paying every proof-of-work toll it is asked for.
    #
    #   assistant = Kiosk::TestHelpers::Assistant.new(base_url: live_url)
    #   rider     = assistant.register!
    #   assistant.run(rider, name: "reserve", scooter_code: "SK-001")
    class Assistant
      class RegistrationError < StandardError; end

      # The account an assistant registered, and the key that signs its mandates.
      Principal = Data.define(:agent_id, :user_id, :token, :rsa_key)

      attr_reader :wire

      def initialize(base_url:)
        @wire = Wire.new(base_url:, pay_tolls: true)
      end

      def base_url = wire.base_url

      # `pow:` is `:solve`, `:skip` (send no proof) or a String sent verbatim as
      # the proof; `wire_role:` puts a `role` the engine must ignore into the body.
      def register_raw(pow: :solve, wire_role: nil)
        register(pow:, wire_role:).first
      end

      def register!(pow: :solve)
        response, key = register(pow:)
        raise RegistrationError, "register! expected 201, got #{response.status}: #{response.body.inspect}" unless response.status == 201

        Principal.new(agent_id: response.body.fetch('agent_id'), user_id: response.body.fetch('user_id'),
                      token: response.body.fetch('access_token'), rsa_key: key)
      end

      # The unauthenticated request that opens the account-binding ceremony (RFC 8628 §3.1).
      def device_authorization(client_id:, public_key:, **extra)
        wire.post_form('/kiosk/oauth/device_authorization',
                       { 'client_id' => client_id, 'public_key' => public_key }.merge(extra.transform_keys(&:to_s)))
      end

      def kyc(principal, attestation_jws:)
        wire.post('/kiosk/agents/kyc', { kyc_jws: attestation_jws }, wire.bearer(principal.token))
      end

      # `pay_tolls: false` answers a proof-of-work toll instead of paying it.
      def query(principal, name:, headers: {}, pay_tolls: true, **params)
        (pay_tolls ? wire : unpaid).get("/kiosk/#{name}", params, wire.bearer(principal.token).merge(headers))
      end

      def run(principal, name:, headers: {}, **args)
        wire.post("/kiosk/#{name}", args, wire.bearer(principal.token).merge(headers))
      end

      # Signs the two closed AP2 mandates for `checkout_jwt`, unchanged, and pays.
      def pay(principal, checkout_jwt, instrument: 'on_file')
        pay_raw(principal, **Mandate.pay(principal.rsa_key, checkout_jwt, instrument:))
      end

      # On a 402 `payment_setup_required` it calls `payment_setup`, as the hint
      # asks, and sends the same mandates once more. Against stripe-mock the
      # Customer that `payment_setup` maps already lists a card, so that answer settles.
      def pay_raw(principal, checkout:, payment:)
        body   = { checkout_mandate: checkout, payment_mandate: payment }
        answer = wire.post('/kiosk/pay', body, wire.bearer(principal.token))
        return answer unless setup_required?(answer)

        run(principal, name: 'payment_setup')
        wire.post('/kiosk/pay', body, wire.bearer(principal.token))
      end

      # Signs in again with the key it holds.
      def login(key) = wire.post('/kiosk/auth/login', possession(key))

      # Redeems a link code a person minted on the operator's site.
      def claim(code, key) = wire.post('/kiosk/auth/claim', { code: }.merge(possession(key)))

      # Polls for the credential a person grants on the operator's site (RFC 8628 §3.4).
      def device_token(device_code, key)
        wire.post_form('/kiosk/oauth/token', 'grant_type' => 'urn:ietf:params:oauth:grant-type:device_code',
                                             'device_code' => device_code, 'signed' => proof_of_possession(key))
      end

      # A proof that the assistant holds `key`, over a fresh challenge and bound to this origin.
      def proof_of_possession(key)
        _, challenge = wire.get_json('/kiosk/auth/challenge', public_key: key.public_key.to_pem)
        JWT.encode({ aud: base_url, nonce: challenge['challenge'], jti: SecureRandom.uuid, iat: Time.now.to_i }, key, 'RS256')
      end

      # What the origin publishes about itself at `/kiosk/schema`.
      def schema = @schema ||= wire.get_json('/kiosk/schema').last

      def events(principal) = Events.new(base_url:, token: principal.token).tap { (@connections ||= []) << it }

      # Closes every event connection it opened.
      def disconnect = @connections&.each(&:close)

      private

      def register(pow:, wire_role: nil)
        key  = OpenSSL::PKey::RSA.generate(2048)
        body = possession(key)
        body[:role] = wire_role if wire_role
        response = case pow
                   when :solve then wire.post('/kiosk/auth/register', body)
                   when :skip then unpaid.post('/kiosk/auth/register', body)
                   else unpaid.post('/kiosk/auth/register', body, 'Kiosk-PoW' => pow)
                   end
        [response, key]
      end

      def possession(key) = { public_key: key.public_key.to_pem, signed: proof_of_possession(key) }

      def unpaid = Wire.new(base_url:)

      def setup_required?(answer)
        answer.status == 402 && answer.body.is_a?(Hash) && answer.body['code'] == 'payment_setup_required'
      end
    end
  end
end
