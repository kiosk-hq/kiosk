# frozen_string_literal: true

require 'jwt'

module JwtIssuerSpec
  # One pair of keys for the whole file.
  def self.key1 = @key1 ||= OpenSSL::PKey.generate_key('ED25519')
  def self.key2 = @key2 ||= OpenSSL::PKey.generate_key('ED25519')

  def decode(token, **)
    JWT.decode(token, key.key, true, algorithms: ['EdDSA'], **)
  end
end

RSpec.shared_context 'with a configured JWT issuer' do
  include JwtIssuerSpec

  let(:key)        { Kiosk::Server::SigningKey.new(JwtIssuerSpec.key1) }
  let(:other_key)  { Kiosk::Server::SigningKey.new(JwtIssuerSpec.key2) }
  let(:jwks)       { Kiosk::Server::Jwks.build(keys: [key]) }
  let(:issuer)     { 'https://combette.example/kiosk' }
  let(:audience)   { 'https://claude.ai/agent/alice' }

  before do
    Kiosk.configure do |c|
      c.issuer      = issuer
      c.signing_key = key
    end
  end
end

RSpec.shared_context 'with an issued JWT' do
  include_context 'with a configured JWT issuer'

  let(:token) do
    described_class.issue(claims: { sub: 'user-1', role: 'customer' }, audience: audience)
  end
end

RSpec.describe Kiosk::Server::JwtIssuer do
  describe '.issue' do
    include_context 'with a configured JWT issuer'

    it 'produces a JWT carrying the supplied claims and the standard time bounds' do
      token = described_class.issue(claims: { sub: 'user-1', role: 'customer' }, audience: audience)
      payload, header = decode(token)

      expect(header).to include('alg' => 'EdDSA', 'kid' => key.kid, 'typ' => 'JWT')
      expect(payload).to include('sub' => 'user-1', 'role' => 'customer', 'iss' => issuer, 'aud' => audience)
      expect(payload['iat']).to be_a(Integer)
      expect(payload['exp']).to be > payload['iat']
      expect(payload['jti']).to match(/\A[0-9a-f-]+\z/) # UUID
    end

    # `nbf` equals `iat`. An `nbf` ahead of `iat` would make this issuer's own
    # verifier refuse a token it has just minted.
    it 'stamps `nbf` at the issue instant — equal to `iat`, inside the lifetime' do
      now   = Time.utc(2026, 6, 10, 12, 0, 0)
      token = described_class.issue(claims: { sub: 'user-1' }, audience: audience, now: now)
      payload, = decode(token, verify_expiration: false)

      expect(payload['nbf']).to be_a(Integer)
      expect(payload['nbf']).to eq(now.to_i)
      expect(payload['nbf']).to eq(payload['iat'])
      expect(payload['nbf']).to be < payload['exp']
    end

    it 'defaults to a one-hour lifetime' do
      now = Time.utc(2026, 6, 10, 12, 0, 0)
      token = described_class.issue(claims: { sub: 'user-1' }, audience: audience, now: now)
      payload, = decode(token, verify_expiration: false)
      expect(payload['exp'] - payload['iat']).to eq(3600)
    end

    it 'honours an `expires_in` override' do
      token = described_class.issue(claims: { sub: 'user-1' }, audience: audience, expires_in: 60)
      payload, = decode(token)
      expect(payload['exp'] - payload['iat']).to eq(60)
    end

    it 'lets caller-supplied jti pass through (idempotency keys etc.)' do
      token = described_class.issue(claims: { sub: 'user-1', jti: 'fixed-id' }, audience: audience)
      payload, = decode(token)
      expect(payload['jti']).to eq('fixed-id')
    end

    it 'raises when no issuer is configured' do
      Kiosk.configure { |c| c.issuer = nil }
      expect do
        described_class.issue(claims: { sub: 'u' }, audience: audience)
      end.to raise_error(ArgumentError, /issuer is required/)
    end

    it 'raises when the signing key is public-only' do
      pub_only = Kiosk::Server::SigningKey.from_pem(key.key.public_to_pem)
      Kiosk.configure { |c| c.signing_key = pub_only }
      expect do
        described_class.issue(claims: { sub: 'u' }, audience: audience)
      end.to raise_error(ArgumentError, /private key/)
    end
  end

  describe '.verify' do
    include_context 'with an issued JWT'

    it 'round-trips an issued token and returns symbol-keyed claims' do
      claims = described_class.verify(token: token, jwks: jwks, audience: audience)
      expect(claims).to include(sub: 'user-1', role: 'customer', iss: issuer, aud: audience)
      expect(claims[:exp]).to be > claims[:iat]
    end

    it 'accepts the issuer when supplied and matching' do
      claims = described_class.verify(token: token, jwks: jwks, audience: audience, issuer: issuer)
      expect(claims[:iss]).to eq(issuer)
    end

    it 'rejects a wrong audience' do
      expect do
        described_class.verify(token: token, jwks: jwks, audience: 'https://wrong.example')
      end.to raise_error(described_class::AudienceError)
    end

    it 'rejects an expired token' do
      old = described_class.issue(claims: { sub: 'u' }, audience: audience, expires_in: -3600)
      expect do
        described_class.verify(token: old, jwks: jwks, audience: audience)
      end.to raise_error(described_class::ExpiredError)
    end

    it 'rejects a token signed by a key not in the JWKS' do
      Kiosk.configure { |c| c.signing_key = other_key }
      foreign = described_class.issue(claims: { sub: 'u' }, audience: audience)
      expect do
        described_class.verify(token: foreign, jwks: jwks, audience: audience)
      end.to raise_error(described_class::SignatureError)
    end

    # An RSA key under the kid of the JWKS key: only the EdDSA list refuses it.
    it 'rejects a bearer signed RS256 under the kid of the JWKS key' do
      claims = JWT.decode(token, nil, false).first
      rs256 = JWT.encode(claims, OpenSSL::PKey::RSA.generate(2048), 'RS256', { kid: key.kid, typ: 'JWT' })
      expect do
        described_class.verify(token: rs256, jwks: jwks, audience: audience)
      end.to raise_error(described_class::SignatureError)
    end

    it 'rejects a malformed token' do
      expect do
        described_class.verify(token: 'not.a.jwt', jwks: jwks, audience: audience)
      end.to raise_error(described_class::InvalidError)
    end

    it 'rejects a tampered payload' do
      header, payload, signature = token.split('.')
      claims = JSON.parse(Base64.urlsafe_decode64(payload.ljust((payload.size + 3) / 4 * 4, '=')))
      tampered_payload = Base64.urlsafe_encode64(JSON.generate(claims.merge('role' => 'admin')), padding: false)
      tampered = [header, tampered_payload, signature].join('.')
      expect do
        described_class.verify(token: tampered, jwks: jwks, audience: audience)
      end.to raise_error(described_class::SignatureError)
    end

    it 'respects clock skew leeway for slightly-in-the-future iat' do
      future = described_class.issue(claims: { sub: 'u' }, audience: audience, now: Time.current + 30)
      # The default leeway is 60s, so a token 30s ahead is accepted.
      expect do
        described_class.verify(token: future, jwks: jwks, audience: audience)
      end.not_to raise_error
    end

    describe 'revocation' do
      let(:agent_token) do
        described_class.issue(claims: { sub: 'u', agent_id: 'a-1' }, audience: audience)
      end
      let(:store) { Kiosk.configuration.revocation_store }

      it 'rejects a token whose agent has been revoked as of now' do
        agent_token # issue first (iat = now)
        store.revoke_all('a-1', at: Time.now.to_i + 120) # watermark ahead of iat
        expect do
          described_class.verify(token: agent_token, jwks: jwks, audience: audience)
        end.to raise_error(described_class::RevokedError)
      end

      it 'accepts a token issued after the revocation watermark (fresh login survives)' do
        store.revoke_all('a-1', at: Time.now.to_i - 120) # watermark in the past
        fresh = described_class.issue(claims: { sub: 'u', agent_id: 'a-1' }, audience: audience)
        expect do
          described_class.verify(token: fresh, jwks: jwks, audience: audience)
        end.not_to raise_error
      end
    end
  end

  describe '.normalize_jwks input polymorphism' do
    include_context 'with a configured JWT issuer'

    let(:token) { described_class.issue(claims: { sub: 'u' }, audience: audience) }

    {
      'accepts an Array<SigningKey>' => ->(key) { [key] },
      'accepts a single SigningKey' => ->(key) { key },
      'accepts a fully-formed JWKS Hash' => ->(key) { { keys: [key.to_jwk] } }
    }.each do |description, jwks_for|
      it description do
        expect do
          described_class.verify(token: token, jwks: jwks_for.call(key), audience: audience)
        end.not_to raise_error
      end
    end

    it 'rejects an unsupported input type' do
      expect do
        described_class.verify(token: token, jwks: 42, audience: audience)
      end.to raise_error(ArgumentError, /jwks must be/)
    end
  end
end
