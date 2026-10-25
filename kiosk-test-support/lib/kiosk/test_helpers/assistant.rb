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
    # An assistant over HTTP: registers its key as an OAuth client, then
    # queries, runs and pays as the principal its token names, paying every
    # proof-of-work toll it is asked for.
    #
    #   assistant = Kiosk::TestHelpers::Assistant.new(base_url: live_url)
    #   rider     = assistant.register!
    #   assistant.run(rider, name: "reserve", scooter_code: "SK-001")
    class Assistant
      class RegistrationError < StandardError; end

      # The account an assistant acts for, its client_id (the agent_id), and
      # the key that signs its client assertions, DPoP proofs and mandates.
      Principal = Data.define(:agent_id, :user_id, :token, :key)

      ASSERTION_TYPE = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
      DEVICE_CODE = 'urn:ietf:params:oauth:grant-type:device_code'

      attr_reader :wire

      def initialize(base_url:)
        @wire = Wire.new(base_url:, pay_tolls: true)
      end

      def base_url = wire.base_url

      # Registers `key` (RFC 7591). `pow:` is `:solve`, `:skip` (send no proof)
      # or a String sent verbatim as the proof; `wire_role:` puts a `role` the
      # engine must ignore into the body.
      def register_raw(pow: :solve, wire_role: nil, key: Dpop.generate_key)
        body = { jwks: jwks(key), token_endpoint_auth_method: 'private_key_jwt' }
        body[:role] = wire_role if wire_role
        case pow
        when :solve then wire.post('/kiosk/oauth/register', body)
        when :skip then unpaid.post('/kiosk/oauth/register', body)
        else unpaid.post('/kiosk/oauth/register', body, 'Kiosk-PoW' => pow)
        end
      end

      # A new key, registered: the principal has a client_id and no token yet.
      def register_client!(pow: :solve)
        key  = Dpop.generate_key
        resp = register_raw(pow:, key:)
        raise RegistrationError, "registration expected 201, got #{resp.status}: #{resp.body.inspect}" unless resp.status == 201

        Principal.new(agent_id: resp.body.fetch('client_id'), user_id: nil, token: nil, key: key)
      end

      # A new key, registered, holding its first token.
      def register!(pow: :solve) = signed_in(register_client!(pow:))

      # The principal holding a new token from the client_credentials grant.
      def signed_in(principal)
        response = token(principal)
        raise RegistrationError, "token request expected 200, got #{response.status}: #{response.body.inspect}" unless response.status == 200

        access_token = response.body.fetch('access_token')
        principal.with(token: access_token, user_id: JWT.decode(access_token, nil, false).first['sub'])
      end

      # Asks the token endpoint for a token of the principal's client (RFC 6749 §4.4).
      def token(principal) = token_request(principal, 'grant_type' => 'client_credentials')

      # Polls for the token a person grants on the operator's site (RFC 8628 §3.4).
      def device_token(device_code, principal)
        token_request(principal, 'grant_type' => DEVICE_CODE, 'device_code' => device_code)
      end

      # Opens the account-binding ceremony (RFC 8628 §3.1), with whatever else the caller sends.
      def device_authorization(principal, **extra)
        wire.post_form('/kiosk/oauth/device_authorization', assertion_params(principal).merge(extra.transform_keys(&:to_s)))
      end

      def kyc(principal, attestation_jws:)
        wire.post('/kiosk/agents/kyc', { kyc_jws: attestation_jws }, credential(principal))
      end

      # `pay_tolls: false` answers a proof-of-work toll instead of solving it.
      def query(principal, name:, headers: {}, pay_tolls: true, **params)
        (pay_tolls ? wire : unpaid).get("/kiosk/#{name}", params, credential(principal).merge(headers))
      end

      def run(principal, name:, headers: {}, **args)
        wire.post("/kiosk/#{name}", args, credential(principal).merge(headers))
      end

      # Signs the two closed AP2 mandates for `checkout_jwt`, unchanged, and pays.
      def pay(principal, checkout_jwt, instrument: 'on_file')
        pay_raw(principal, **Mandate.pay(principal.key, checkout_jwt, instrument:))
      end

      # On a 402 `payment_setup_required` it calls `payment_setup`, as the hint
      # asks, and sends the same mandates once more. Against stripe-mock the
      # Customer that `payment_setup` maps already lists a card, so that answer settles.
      def pay_raw(principal, checkout:, payment:)
        body   = { checkout_mandate: checkout, payment_mandate: payment }
        answer = wire.post('/kiosk/pay', body, credential(principal))
        return answer unless setup_required?(answer)

        run(principal, name: 'payment_setup')
        wire.post('/kiosk/pay', body, credential(principal))
      end

      # Puts a new key on the principal's client (spec Section 5.7): the old
      # key's assertion names the new key, and the new key signs its own. The
      # answer's Principal holds the new key and a token bound to it.
      def rotate(principal, new_key: Dpop.generate_key)
        body = { client_assertion_type: ASSERTION_TYPE,
                 client_assertion: client_assertion(principal, new_key: Dpop.thumbprint(new_key)),
                 new_client_assertion: client_assertion(principal.with(key: new_key)), jwks: jwks(new_key) }
        response = wire.post('/kiosk/auth/rotate', body)
        return response unless response.status == 200

        signed_in(principal.with(key: new_key))
      end

      # Redeems a link code a person minted on the operator's site; answers 204.
      def claim(code, principal) = wire.post('/kiosk/auth/claim', { code:, **assertion_params(principal) })

      # A client assertion (RFC 7523 §3) that the principal's key signs for this
      # origin. `claims` adds or replaces members, such as the `new_key` of a rotation.
      def client_assertion(principal, **claims)
        payload = { iss: principal.agent_id, sub: principal.agent_id, aud: base_url, exp: Time.now.to_i + 60,
                    jti: SecureRandom.uuid, **claims }
        JWT.encode(payload, principal.key, Dpop.algorithm(principal.key))
      end

      # What the origin publishes about itself at `/kiosk/schema`.
      def schema = @schema ||= wire.get_json('/kiosk/schema').last

      def events(principal) = Events.new(base_url:, token: principal.token, key: principal.key).tap { (@connections ||= []) << it }

      # Closes every event connection it opened.
      def disconnect = @connections&.each(&:close)

      private

      def jwks(key) = { keys: [Dpop.jwk(key)] }

      def assertion_params(principal)
        { 'client_assertion_type' => ASSERTION_TYPE, 'client_assertion' => client_assertion(principal) }
      end

      # A token request carries a DPoP proof of the registered key, with no token yet.
      def token_request(principal, form)
        wire.post_form('/kiosk/oauth/token', form.merge(assertion_params(principal)), wire.dpop(nil, principal.key))
      end

      def unpaid = Wire.new(base_url:)

      # The principal's token and key, which the protocol signs a DPoP proof with.
      def credential(principal) = wire.dpop(principal.token, principal.key)

      def setup_required?(answer)
        answer.status == 402 && answer.body.is_a?(Hash) && answer.body['code'] == 'payment_setup_required'
      end
    end
  end
end
