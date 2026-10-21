# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'jwt'
require 'openssl'
require 'securerandom'
require 'uri'

module Kiosk
  module TestHelpers
    # The two headers of a call that carries an access token (RFC 9449): the
    # token as `Authorization: DPoP`, and a proof that the token's key signs
    # for this method and URL. A token request has no token yet: it sends
    # only the proof, with no `ath`.
    #
    #   Dpop.headers(token, key, method: 'GET', url: 'https://shop.example/kiosk/catalog')
    #   Dpop.headers(nil, key, method: 'POST', url: 'https://shop.example/kiosk/oauth/token')
    module Dpop
      module_function

      def headers(token, key, method:, url:, iat: Time.now.to_i)
        proof = { 'DPoP' => proof(token, key, method:, url:, iat:) }
        token ? { 'Authorization' => "DPoP #{token}", **proof } : proof
      end

      # The same two headers as Rack env entries.
      def env(token, key, method:, url:, iat: Time.now.to_i)
        { 'HTTP_AUTHORIZATION' => "DPoP #{token}", 'HTTP_DPOP' => proof(token, key, method:, url:, iat:) }
      end

      # `url` loses its query and fragment: `htu` names the resource, not the arguments.
      def proof(token, key, method:, url:, iat: Time.now.to_i)
        uri = URI(url.to_s)
        htu = "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}#{uri.path}"
        payload = { jti: SecureRandom.uuid, htm: method.to_s.upcase, htu: htu, iat: iat }
        payload[:ath] = ath(token) if token
        JWT.encode(payload, key, 'RS256', { typ: 'dpop+jwt', jwk: jwk(key) })
      end

      def ath(token) = Base64.urlsafe_encode64(Digest::SHA256.digest(token.to_s), padding: false)

      # The RFC 7638 thumbprint of the key: a token's `cnf.jkt`, a rotation's `new_key`.
      def thumbprint(key)
        canonical = JSON.generate({ e: b64(key.e), kty: 'RSA', n: b64(key.n) })
        Base64.urlsafe_encode64(Digest::SHA256.digest(canonical), padding: false)
      end

      # The public JWK (RFC 7517) of the key: a proof's `jwk`, a registration's `jwks` member.
      def jwk(key)
        { kty: 'RSA', n: b64(key.n), e: b64(key.e) }
      end

      def b64(number) = Base64.urlsafe_encode64(number.to_s(2), padding: false)
      private_class_method :b64
    end
  end
end
