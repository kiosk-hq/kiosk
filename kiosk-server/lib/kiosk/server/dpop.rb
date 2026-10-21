# frozen_string_literal: true

require 'base64'
require 'digest'
require 'jwt'
require 'uri'

module Kiosk
  module Server
    # RFC 9449 (spec Section 5.6): a token request, and a request that carries
    # an access token, come with a proof that the registered key signed for
    # this request. The proof's iat window is the replay bound; no nonce is
    # issued and no jti is kept.
    module Dpop
      SCHEME = 'DPoP'
      TYPE   = 'dpop+jwt'
      WINDOW = 60
      CLAIMS = %w[jti htm htu iat].freeze

      # The `WWW-Authenticate` value of a 401 on a request that needs a token.
      CHALLENGE = %(#{SCHEME} algs="#{AssistantKey::ALGORITHMS.join(' ')}").freeze

      HINT = 'send `Authorization: DPoP <access_token>` and one `DPoP` header: a JWS with typ dpop+jwt, ' \
             "alg #{AssistantKey::ALGORITHMS.join(' or ')} and the public jwk of your registered key, signed by " \
             'that key, whose payload carries jti, htm (the method), htu (the URL with no query), iat (now) ' \
             'and ath (base64url SHA-256 of the access token)'.freeze

      TOKEN_REQUEST_HINT = 'send one `DPoP` header: a JWS with typ dpop+jwt, ' \
                           "alg #{AssistantKey::ALGORITHMS.join(' or ')} and the public jwk of your registered " \
                           'key, signed by that key, whose payload carries jti, htm POST, htu (the token URL) ' \
                           'and iat (now)'.freeze

      # A proof that does not hold.
      class Invalid < StandardError; end

      module_function

      # The access token of an `Authorization: DPoP <token>` header, else nil.
      def token(authorization)
        authorization.to_s[/\A#{SCHEME}\s+(\S+)\z/io, 1]
      end

      # Raises Errors::AccessTokenRefused unless `proof` is the key `jkt`'s proof
      # for this method, URL and token, signed within {WINDOW} seconds of now.
      def verify!(proof, token:, jkt:, method:, url:)
        raise Invalid, 'the access token is bound to no key' if jkt.to_s.empty?

        claims = check!(proof, jkt:, method:, url:, key: 'the key the token is bound to')
        raise Invalid, 'the DPoP proof ath is not the hash of this token' unless claims['ath'] == hash_of(token)
      rescue Invalid => e
        raise Errors::AccessTokenRefused, e.message
      end

      # Raises OauthError `invalid_dpop_proof` unless `proof` is the proof of
      # the registered key `jkt` for this token request. It carries no `ath`:
      # there is no token yet.
      def verify_token_request!(proof, jkt:, url:)
        check!(proof, jkt:, method: 'POST', url:, key: 'your registered key')
      rescue Invalid => e
        raise OauthError.new(:invalid_dpop_proof, "#{e.message}: #{TOKEN_REQUEST_HINT}")
      end

      # The base64url SHA-256 of the token: the `ath` a proof carries.
      def hash_of(token) = Base64.urlsafe_encode64(Digest::SHA256.digest(token.to_s), padding: false)

      # `key` names the key `jkt` is the thumbprint of.
      def check!(proof, jkt:, method:, url:, key:)
        raise Invalid, 'one DPoP header is required' if proof.to_s.empty? || proof.include?(',')

        signer, claims = decode(proof)
        raise Invalid, "the DPoP proof key is not #{key}" unless AssistantKey.thumbprint(signer) == jkt

        check_request!(claims, method, url)
        claims
      end

      def check_request!(claims, method, url)
        raise Invalid, 'the DPoP proof htm is not this request method' unless claims['htm'] == method
        raise Invalid, 'the DPoP proof htu is not this request URL' unless same_url?(claims['htu'], url)
        raise Invalid, 'the DPoP proof iat is not within 60 seconds of now' unless (claims['iat'].to_i - Time.now.to_i).abs <= WINDOW
      end

      def decode(proof)
        key = nil
        claims, = ::JWT.decode(proof, nil, true, algorithms: AssistantKey::ALGORITHMS, required_claims: CLAIMS) do |header|
          key = header_key(header)
        end
        [key, claims]
      rescue ::JWT::DecodeError, Errors::BadRequest
        raise Invalid, 'the DPoP proof is not a JWS that its jwk signed, with the claims of RFC 9449'
      end

      def header_key(header)
        raise Invalid, 'the DPoP proof typ is not dpop+jwt' unless header['typ'] == TYPE

        jwk = header['jwk']
        raise Invalid, 'the DPoP proof carries no public jwk' unless jwk.is_a?(Hash) && !jwk.keys.intersect?(AssistantKey::PRIVATE_MEMBERS)

        AssistantKey.from_jwk(jwk)
      end

      # Scheme and host without case, a default port dropped (RFC 9449 Section 4.3).
      def same_url?(htu, url)
        Kiosk::Configuration.normalize_origin(htu) == Kiosk::Configuration.normalize_origin(url) &&
          URI.parse(htu.to_s).path == URI.parse(url).path
      rescue URI::InvalidURIError
        false
      end

      private_class_method :check!, :check_request!, :decode, :header_key, :same_url?
    end
  end
end
