# frozen_string_literal: true

require 'base64'
require 'digest'
require 'jwt'
require 'openssl'
require 'securerandom'
require 'uri'
require 'kiosk/server/eddsa'

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

      # A new assistant key: Ed25519, or P-256 for `ES256`.
      def generate_key(algorithm = 'EdDSA')
        algorithm == 'ES256' ? OpenSSL::PKey::EC.generate('prime256v1') : OpenSSL::PKey.generate_key('ED25519')
      end

      # The JOSE algorithm the key signs with: EdDSA or ES256.
      def algorithm(key) = Kiosk::Server::Jwk.algorithm(key)

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
        JWT.encode(payload, key, algorithm(key), { typ: 'dpop+jwt', jwk: jwk(key) })
      end

      def ath(token) = Base64.urlsafe_encode64(Digest::SHA256.digest(token.to_s), padding: false)

      # The RFC 7638 thumbprint of the key: a token's `cnf.jkt`, a rotation's `new_key`.
      def thumbprint(key) = Kiosk::Server::Jwk.thumbprint(key)

      # The public JWK (RFC 7517) of the key: a proof's `jwk`, a registration's `jwks` member.
      def jwk(key) = Kiosk::Server::Jwk.public_members(key)
    end
  end
end
