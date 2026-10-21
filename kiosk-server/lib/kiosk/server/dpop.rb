# frozen_string_literal: true

require 'base64'
require 'digest'
require 'jwt'
require 'uri'

module Kiosk
  module Server
    # RFC 9449 (spec Section 5.6): an access token works only with a proof that
    # its bound key signed for this request. The proof's iat window is the
    # replay bound; no nonce is issued and no jti is kept.
    module Dpop
      SCHEME    = 'DPoP'
      TYPE      = 'dpop+jwt'
      ALGORITHM = 'RS256'
      WINDOW    = 60
      CLAIMS    = %w[jti htm htu iat ath].freeze

      # The `WWW-Authenticate` value of a 401 on a request that needs a token.
      CHALLENGE = %(#{SCHEME} algs="#{ALGORITHM}").freeze

      HINT = 'send `Authorization: DPoP <access_token>` and one `DPoP` header: a JWS with typ dpop+jwt, ' \
             'alg RS256 and the public jwk of your registered key, signed by that key, whose payload ' \
             'carries jti, htm (the method), htu (the URL with no query), iat (now) and ath ' \
             '(base64url SHA-256 of the access token)'

      # The members of a JWK that only a private key has.
      PRIVATE_MEMBERS = %w[d p q dp dq qi].freeze

      module_function

      # The access token of an `Authorization: DPoP <token>` header, else nil.
      def token(authorization)
        authorization.to_s[/\A#{SCHEME}\s+(\S+)\z/io, 1]
      end

      # Raises Errors::AccessTokenRefused unless `proof` is the key `jkt`'s proof
      # for this method, URL and token, signed within {WINDOW} seconds of now.
      def verify!(proof, token:, jkt:, method:, url:)
        refuse!('the access token is bound to no key') if jkt.to_s.empty?
        refuse!('one DPoP header is required') if proof.to_s.empty? || proof.include?(',')

        key, claims = decode(proof)
        refuse!('the DPoP proof key is not the key the token is bound to') unless SigningKey.new(key).kid == jkt
        check_request!(claims, method, url)
        check_token!(claims, token)
      end

      def check_request!(claims, method, url)
        refuse!('the DPoP proof htm is not this request method') unless claims['htm'] == method
        refuse!('the DPoP proof htu is not this request URL') unless same_url?(claims['htu'], url)
      end

      def check_token!(claims, token)
        refuse!('the DPoP proof iat is not within 60 seconds of now') unless (claims['iat'].to_i - Time.now.to_i).abs <= WINDOW
        refuse!('the DPoP proof ath is not the hash of this token') unless claims['ath'] == hash_of(token)
      end

      # The base64url SHA-256 of the token: the `ath` a proof carries.
      def hash_of(token) = Base64.urlsafe_encode64(Digest::SHA256.digest(token.to_s), padding: false)

      def decode(proof)
        key = nil
        claims, = ::JWT.decode(proof, nil, true, algorithms: [ALGORITHM], required_claims: CLAIMS) do |header|
          key = header_key(header)
        end
        [key, claims]
      rescue ::JWT::DecodeError, OpenSSL::PKey::PKeyError, ArgumentError
        refuse!('the DPoP proof is not a JWS that its jwk signed, with the claims of RFC 9449')
      end

      def header_key(header)
        jwk = header['jwk']
        refuse!('the DPoP proof typ is not dpop+jwt') unless header['typ'] == TYPE
        refuse!('the DPoP proof carries no public jwk') unless jwk.is_a?(Hash) && !jwk.keys.intersect?(PRIVATE_MEMBERS)

        ::JWT::JWK.import(jwk).public_key
      end

      # Scheme and host without case, a default port dropped (RFC 9449 Section 4.3).
      def same_url?(htu, url)
        Kiosk::Configuration.normalize_origin(htu) == Kiosk::Configuration.normalize_origin(url) &&
          URI.parse(htu.to_s).path == URI.parse(url).path
      rescue URI::InvalidURIError
        false
      end

      def refuse!(detail)
        raise Errors::AccessTokenRefused, detail
      end

      private_class_method :check_request!, :check_token!, :decode, :header_key, :same_url?, :refuse!
    end
  end
end
