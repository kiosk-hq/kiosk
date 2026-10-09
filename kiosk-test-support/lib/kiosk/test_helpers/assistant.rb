# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"
require "uri"
require "jwt"
require "kiosk/test_helpers/wire"
require "kiosk/test_helpers/assistant/events"

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

        Principal.new(agent_id: response.body.fetch("agent_id"), user_id: response.body.fetch("user_id"),
                      token: response.body.fetch("access_token"), rsa_key: key)
      end

      # The unauthenticated request that opens the account-binding ceremony (RFC 8628 §3.1).
      def device_authorization(client_id:, public_key:, **extra)
        wire.post_form("/kiosk/oauth/device_authorization",
                       { "client_id" => client_id, "public_key" => public_key }.merge(extra.transform_keys(&:to_s)))
      end

      def kyc(principal, attestation_jws:)
        wire.post("/kiosk/agents/kyc", { kyc_jws: attestation_jws }, wire.bearer(principal.token))
      end

      # `pay_tolls: false` answers a proof-of-work toll instead of paying it.
      def query(principal, name:, headers: {}, pay_tolls: true, **params)
        (pay_tolls ? wire : unpaid).get("/kiosk/#{name}", params, wire.bearer(principal.token).merge(headers))
      end

      def run(principal, name:, headers: {}, **args)
        wire.post("/kiosk/#{name}", args, wire.bearer(principal.token).merge(headers))
      end

      # The intent and cart mandates for a quote of `total` cents, for #pay.
      def mandates(principal, total:, scope:, line_items:, currency: "eur")
        now    = Time.now.to_i
        common = { user_id: principal.user_id, agent_id: principal.agent_id, iss: base_url, currency:, iat: now, exp: now + 600 }
        intent = common.merge(id: SecureRandom.uuid, scope:, cap_amount_cents: total)
        { intent:, cart: common.merge(id: SecureRandom.uuid, intent_mandate_id: intent[:id], total_amount_cents: total, line_items:) }
      end

      def pay(principal, intent:, cart:, payment_method: "pm_demo")
        payment = payment_mandate(principal, cart:, payment_method:)
        pay_raw(principal, intent_jws: sign_mandate(principal, intent), cart_jws: sign_mandate(principal, cart),
                           payment_jws: sign_mandate(principal, payment))
      end

      def pay_raw(principal, intent_jws:, cart_jws:, payment_jws:)
        body = { intent_mandate_jws: intent_jws, cart_mandate_jws: cart_jws, payment_mandate_jws: payment_jws }
        wire.post("/kiosk/pay", body, wire.bearer(principal.token))
      end

      def payment_mandate(principal, cart:, payment_method: "pm_demo")
        cart = cart.transform_keys(&:to_sym)
        now  = Time.now.to_i
        { id: SecureRandom.uuid, cart_mandate_id: cart[:id], user_id: principal.user_id, agent_id: principal.agent_id,
          iss: cart[:iss], payment_method:, amount_cents: cart[:total_amount_cents], currency: cart[:currency],
          exp: now + 600, iat: now }
      end

      def sign_mandate(principal, payload) = JWT.encode(payload, principal.rsa_key, "RS256")

      # Signs in again with the key it holds.
      def login(key) = wire.post("/kiosk/auth/login", possession(key))

      # Redeems a link code a person minted on the operator's site.
      def claim(code, key) = wire.post("/kiosk/auth/claim", { code: }.merge(possession(key)))

      # Polls for the credential a person grants on the operator's site (RFC 8628 §3.4).
      def device_token(device_code, key)
        wire.post_form("/kiosk/oauth/token", "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
                                             "device_code" => device_code, "signed" => proof_of_possession(key))
      end

      # A proof that the assistant holds `key`, over a fresh challenge and bound to this origin.
      def proof_of_possession(key)
        _, challenge = wire.get_json("/kiosk/auth/challenge", public_key: key.public_key.to_pem)
        JWT.encode({ aud: base_url, nonce: challenge["challenge"], jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
      end

      # What the origin publishes about itself at `/kiosk/schema`.
      def schema = @schema ||= wire.get_json("/kiosk/schema").last

      def events(principal) = Events.new(base_url:, token: principal.token).tap { (@connections ||= []) << _1 }

      # Closes every event connection it opened.
      def disconnect = @connections&.each(&:close)

      private

      def register(pow:, wire_role: nil)
        key  = OpenSSL::PKey::RSA.generate(2048)
        body = possession(key)
        body[:role] = wire_role if wire_role
        response = case pow
                   when :solve then wire.post("/kiosk/auth/register", body)
                   when :skip then unpaid.post("/kiosk/auth/register", body)
                   else unpaid.post("/kiosk/auth/register", body, "Kiosk-PoW" => pow)
                   end
        [response, key]
      end

      def possession(key) = { public_key: key.public_key.to_pem, signed: proof_of_possession(key) }

      def unpaid = Wire.new(base_url:)
    end
  end
end
