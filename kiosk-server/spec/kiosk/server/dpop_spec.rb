# frozen_string_literal: true

require 'base64'
require 'jwt'
require 'securerandom'

# Spec Section 5.6: the DPoP proof (RFC 9449) that makes an access token
# usable. Every refusal is a 401 that names the DPoP scheme.
RSpec.describe Kiosk::Server::Dpop do
  let(:url)   { 'https://demo.example/kiosk/catalog' }
  let(:token) { 'the.access.token' }
  let(:proof) { Kiosk::TestHelpers::Dpop.proof(token, agent_key, method: 'GET', url: url) }

  # The arguments of a request this proof was made for, with `changes` applied.
  def verify(**changes)
    proof = changes.delete(:proof) { self.proof }
    described_class.verify!(proof, token:, jkt: agent_jkt, method: 'GET', url:, **changes)
  end

  def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

  def claims(**changes)
    { jti: SecureRandom.uuid, htm: 'GET', htu: url, iat: Time.now.to_i,
      ath: Kiosk::TestHelpers::Dpop.ath(token) }.merge(changes)
  end

  def public_jwk(key = agent_key) = Kiosk::TestHelpers::Dpop.jwk(key)

  # A proof built by hand, for the shapes the helper never makes.
  def hand_proof(payload: claims, header: { typ: 'dpop+jwt', jwk: public_jwk }, key: agent_key)
    JWT.encode(payload, key, 'EdDSA', header)
  end

  def expect_refused(message, **)
    expect { verify(**) }.to raise_error(Kiosk::Server::Errors::AccessTokenRefused, message) do |error|
      expect(error.http_status).to eq(401)
      expect(error.response_headers).to eq('WWW-Authenticate' => described_class.challenge)
    end
  end

  describe '.token' do
    it 'reads the token of a DPoP Authorization header, the scheme in any case' do
      expect(described_class.token('DPoP abc')).to eq('abc')
      expect(described_class.token('dpop abc')).to eq('abc')
    end

    it 'reads no token from a Bearer header, or from none' do
      expect(described_class.token('Bearer abc')).to be_nil
      expect(described_class.token(nil)).to be_nil
    end
  end

  describe '.verify!' do
    it 'accepts the proof of the bound key for this method, URL and token' do
      expect { verify }.not_to raise_error
    end

    # RFC 9449 Section 4.3: scheme and host compare without case, and a
    # default port is the same URL as none.
    it 'accepts a URL that differs only in the case of its host or an explicit default port' do
      expect { verify(url: 'https://DEMO.example:443/kiosk/catalog') }.not_to raise_error
    end

    it 'refuses a token bound to no key' do
      expect_refused(/bound to no key/, jkt: nil)
    end

    it 'refuses a request with no DPoP header' do
      expect_refused(/one DPoP header is required/, proof: nil)
    end

    it 'refuses two DPoP headers joined with a comma' do
      expect_refused(/one DPoP header is required/, proof: "#{proof},#{proof}")
    end

    it 'refuses a proof whose typ is not dpop+jwt' do
      expect_refused(/typ is not dpop\+jwt/, proof: hand_proof(header: { typ: 'JWT', jwk: public_jwk }))
    end

    it 'refuses a proof whose jwk carries a private member' do
      jwk = public_jwk.merge(d: b64(agent_key.raw_private_key))
      expect_refused(/carries no public jwk/, proof: hand_proof(header: { typ: 'dpop+jwt', jwk: jwk }))
    end

    it 'refuses a proof that another key signed' do
      other = OpenSSL::PKey.generate_key('ED25519')
      expect_refused(/not the key the token is bound to/, proof: Kiosk::TestHelpers::Dpop.proof(token, other, method: 'GET', url: url))
    end

    it 'refuses a proof whose jwk is not the key that signed it' do
      other = OpenSSL::PKey.generate_key('ED25519')
      expect_refused(/not a JWS that its jwk signed/, proof: hand_proof(key: other))
    end

    it 'refuses a proof for another method' do
      expect_refused(/htm is not this request method/, method: 'POST')
    end

    it 'refuses a proof for another URL' do
      expect_refused(/htu is not this request URL/, url: 'https://demo.example/kiosk/my_orders')
    end

    it 'refuses a proof for another origin' do
      expect_refused(/htu is not this request URL/, url: 'https://other.example/kiosk/catalog')
    end

    it 'refuses a proof signed more than 60 seconds ago, or more than 60 seconds ahead' do
      expect_refused(/iat is not within 60 seconds/, proof: hand_proof(payload: claims(iat: Time.now.to_i - 61)))
      expect_refused(/iat is not within 60 seconds/, proof: hand_proof(payload: claims(iat: Time.now.to_i + 61)))
    end

    it 'accepts a proof at the edge of its window' do
      expect { verify(proof: hand_proof(payload: claims(iat: Time.now.to_i - 59))) }.not_to raise_error
    end

    it 'refuses a proof whose ath is the hash of another token' do
      expect_refused(/ath is not the hash of this token/, token: 'another.access.token')
    end

    it 'refuses a proof that lacks a claim RFC 9449 requires' do
      expect_refused(/not a JWS that its jwk signed/, proof: hand_proof(payload: claims.except(:jti)))
    end

    it 'refuses a proof with no `ath` on a request that carries a token' do
      expect_refused(/ath is not the hash of this token/, proof: hand_proof(payload: claims.except(:ath)))
    end

    it 'refuses a value that is not a JWS' do
      expect_refused(/not a JWS that its jwk signed/, proof: 'not-a-jws')
    end
  end

  # A token request (spec Section 5.3) carries a proof and no token.
  describe '.verify_token_request!' do
    let(:token_url) { 'https://demo.example/kiosk/oauth/token' }

    def token_proof(key: agent_key, **changes)
      hand_proof(payload: claims(htm: 'POST', htu: token_url, ath: nil, **changes).compact, key: key,
                 header: { typ: 'dpop+jwt', jwk: public_jwk(key) })
    end

    def expect_token_request_refused(message, proof)
      expect { described_class.verify_token_request!(proof, jkt: agent_jkt, url: token_url) }
        .to raise_error(Kiosk::Server::OauthError, message) { |e| expect(e.code).to eq('invalid_dpop_proof') }
    end

    it 'accepts a proof of the registered key with no ath' do
      expect { described_class.verify_token_request!(token_proof, jkt: agent_jkt, url: token_url) }.not_to raise_error
    end

    it 'refuses no proof, a proof of another key, and a proof for another method' do
      expect_token_request_refused(/one DPoP header is required/, nil)
      expect_token_request_refused(/not your registered key/, token_proof(key: OpenSSL::PKey.generate_key('ED25519')))
      expect_token_request_refused(/htm is not this request method/, token_proof(htm: 'GET'))
    end
  end

  it 'names the algorithms of AssistantKey and the protected-resource metadata in its challenge' do
    metadata = 'resource_metadata="https://demo.example/.well-known/oauth-protected-resource"'
    challenge = -> { Kiosk.with_issuer('https://demo.example') { described_class.challenge } }
    expect(challenge.call).to eq(%(DPoP algs="EdDSA", #{metadata}))
    Kiosk.configure { |c| c.assistant_algorithms = %w[EdDSA ES256] }
    expect(challenge.call).to eq(%(DPoP algs="EdDSA ES256", #{metadata}))
  end

  describe 'the algorithm of the proof' do
    let(:p256) { Kiosk::TestHelpers::Dpop.generate_key('ES256') }
    let(:p256_proof) { Kiosk::TestHelpers::Dpop.proof(token, p256, method: 'GET', url: url) }

    def verify_p256 = described_class.verify!(p256_proof, token:, jkt: Kiosk::TestHelpers::Dpop.thumbprint(p256), method: 'GET', url:)

    it 'refuses an ES256 proof of a P-256 key at an operator that accepts EdDSA alone' do
      expect { verify_p256 }.to raise_error(Kiosk::Server::Errors::AccessTokenRefused, /jwk is refused: the key is not an Ed25519 key/)
    end

    it 'accepts an ES256 proof of a P-256 key at an operator that accepts ES256' do
      Kiosk.configure { |c| c.assistant_algorithms = %w[EdDSA ES256] }
      expect { verify_p256 }.not_to raise_error
    end

    it 'refuses an RS256 proof of an RSA key' do
      rsa = OpenSSL::PKey::RSA.generate(2048)
      jwk = { kty: 'RSA', n: b64(rsa.n.to_s(2)), e: b64(rsa.e.to_s(2)) }
      expect_refused(/jwk is refused/, proof: JWT.encode(claims, rsa, 'RS256', { typ: 'dpop+jwt', jwk: jwk }))
    end

    it 'refuses an Ed25519 jwk on a proof whose alg is not EdDSA' do
      expect_refused(/alg is not EdDSA, the algorithm of its jwk/,
                     proof: JWT.encode(claims, 'secret', 'HS256', { typ: 'dpop+jwt', jwk: public_jwk }))
    end

    it 'refuses a proof that its Ed25519 key signed under alg RS256 or ES256' do
      %w[RS256 ES256].each do |alg|
        expect_refused(/alg is not EdDSA, the algorithm of its jwk/,
                       proof: mislabelled_jws(claims, agent_key, alg, { typ: 'dpop+jwt', jwk: public_jwk }))
      end
    end

    it 'refuses a proof that its P-256 key signed under alg EdDSA at an operator that accepts ES256' do
      Kiosk.configure { |c| c.assistant_algorithms = %w[EdDSA ES256] }
      proof = mislabelled_jws(claims, p256, 'EdDSA', { typ: 'dpop+jwt', jwk: public_jwk(p256) })
      expect { described_class.verify!(proof, token:, jkt: Kiosk::TestHelpers::Dpop.thumbprint(p256), method: 'GET', url:) }
        .to raise_error(Kiosk::Server::Errors::AccessTokenRefused, /alg is not ES256, the algorithm of its jwk/) { |e| expect(e.http_status).to eq(401) }
    end
  end
end
