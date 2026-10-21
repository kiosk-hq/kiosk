# frozen_string_literal: true

require 'jwt'
require 'rails'

module Kiosk
  module Server
    # Client authentication by `private_key_jwt`: an RFC 7523 client assertion
    # that the registered key of the client signs. Each refusal says what to fix.
    module ClientAssertion
      TYPE = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'

      # Seconds: the longest life an assertion can have, and the clock difference accepted.
      MAX_LIFETIME = 300
      LEEWAY = 60

      REQUIRED_CLAIMS = %w[iss sub aud exp jti].freeze

      # A refused client assertion. The `/oauth/*` endpoints answer it as
      # `invalid_client`, the other endpoints as `401 unauthenticated`.
      class Refused < StandardError
        attr_reader :hint

        def initialize(message, hint:)
          @hint = hint
          super(message)
        end

        def to_oauth = OauthError.new(:invalid_client, "#{message}: #{hint}")
        def to_problem = Errors::Unauthenticated.new(message, hint: hint)
      end

      # A verified assertion that is not yet spent.
      Verified = Data.define(:client, :claims)

      # Names no origin: a value that a response sends back is what a relaying server would exploit.
      AUDIENCE_HINT = 'sign `aud` = the origin you connected to, taken from your own request URL, ' \
                      'never from a value that a response sends back'

      CLAIMS_HINT = "the payload carries #{REQUIRED_CLAIMS.join(', ')}: `iss` and `sub` are your client_id, " \
                    '`aud` is the origin you connected to, `exp` is at most 300 seconds from now, ' \
                    '`jti` is a new unique id'.freeze

      UNKNOWN_CLIENT_HINT = 'register your key at registration_url; the answer carries your client_id. ' \
                            'A client that the account holder unlinked is unknown'

      SIGNATURE_HINT = 'a client assertion is a compact JWS that the private key of your registered key signs: ' \
                       'EdDSA for an Ed25519 key, ES256 for a P-256 key'

      module_function

      # Verifies and spends the assertion; answers its client.
      # @raise [Refused]
      def authenticate!(type, assertion, client_id: nil)
        verified = verify(type, assertion, client_id: client_id)
        spend!(verified)
        verified.client
      end

      # Every check but the single use. `key` replaces the registered key: a
      # rotation verifies the assertion of the new key with it.
      # @raise [Refused]
      def verify(type, assertion, client_id: nil, key: nil)
        check_type!(type, assertion)
        client = client_of(assertion)
        claims = decode(assertion, key || registered_key(client))
        check_claims!(claims, client_id)
        Verified.new(client: client, claims: claims)
      end

      # Claims the `jti` in the spent-id set until the assertion can no longer be accepted.
      # @raise [Refused] when the `jti` is spent already
      def spend!(verified)
        id = "client_assertion:#{verified.client.id}:#{verified.claims['jti']}"
        return if Kiosk.configuration.pow_spent_store.claim(id, verified.claims['exp'].to_i + LEEWAY)

        refuse!('client assertion already used', 'sign a new client assertion with a new `jti` for each request')
      end

      def check_type!(type, assertion)
        if assertion.to_s.empty?
          refuse!('client authentication required',
                  "send client_assertion_type = #{TYPE} and client_assertion, a JWT that your registered key signs")
        end
        refuse!('unsupported client_assertion_type', "send client_assertion_type = #{TYPE}") unless type == TYPE
      end

      # The client the `sub` names. The signature is checked after this, with its key.
      def client_of(assertion)
        payload = ::JWT.decode(assertion.to_s, nil, false).first
        Client.find(payload.is_a?(Hash) ? payload['sub'] : nil) || refuse!('unknown client', UNKNOWN_CLIENT_HINT)
      rescue ::JWT::DecodeError
        refuse!('client assertion is not a JWT', SIGNATURE_HINT)
      end

      # A key that this operator accepts no longer, such as a P-256 key once ES256 is off.
      def registered_key(client)
        client.key
      rescue Errors::BadRequest
        refuse!('the registered key is not accepted here',
                "this operator accepts #{AssistantKey.algorithms.join(' and ')} keys: register a new key at registration_url")
      end

      def decode(assertion, key)
        ::JWT.decode(assertion.to_s, key, true, algorithms: [AssistantKey.algorithm(key)],
                                                required_claims: REQUIRED_CLAIMS, leeway: LEEWAY).first
      rescue ::JWT::MissingRequiredClaim
        refuse!('client assertion is missing a required claim', CLAIMS_HINT)
      rescue ::JWT::ExpiredSignature
        refuse!('client assertion expired', 'sign a new client assertion')
      rescue ::JWT::DecodeError
        refuse!('client assertion signature invalid', SIGNATURE_HINT)
      end

      def check_claims!(claims, client_id)
        refuse!('client assertion iss is not its sub', CLAIMS_HINT) unless claims['iss'] == claims['sub']
        refuse!('client_id is not the client assertion sub', CLAIMS_HINT) if client_id.present? && client_id != claims['sub']
        check_audience!(claims['aud'])
        return if claims['exp'].to_i <= Time.now.to_i + MAX_LIFETIME

        refuse!('client assertion lives too long', "set `exp` at most #{MAX_LIFETIME} seconds after now")
      end

      # `aud` names this origin as its only value (RFC 7523bis Section 4).
      def check_audience!(aud)
        issuer = Kiosk.current_issuer
        return if Array(aud) == [issuer]

        log_audience_mismatch(aud, issuer)
        refuse!('client assertion audience mismatch', AUDIENCE_HINT)
      end

      # Operator log only, because the answer must not name an origin: the
      # caller signed a wrong value, or this deployment does not serve the origin it reached.
      def log_audience_mismatch(aud, issuer)
        message = "[kiosk] client assertion audience mismatch: the caller signed aud=#{aud.inspect}, " \
                  "the issuer for this request is #{issuer.inspect}. If the signed value is an origin " \
                  'your assistants actually reach, list it in `c.issuer` or `c.additional_origins`.'
        logger = ::Rails.logger
        logger ? logger.warn(message) : warn(message)
      end

      def refuse!(message, hint)
        raise Refused.new(message, hint: hint)
      end

      private_class_method :check_type!, :client_of, :registered_key, :decode, :check_claims!, :check_audience!,
                           :log_audience_mismatch, :refuse!
    end
  end
end
