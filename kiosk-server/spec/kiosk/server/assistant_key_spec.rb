# frozen_string_literal: true

# The assistant's public key: loaded from a JWK or a PEM, held to the key
# types this operator accepts, and named by its RFC 7638 thumbprint.
RSpec.describe Kiosk::Server::AssistantKey do
  let(:jwk) { described_class.to_jwk(agent_key) }
  let(:p256) { Kiosk::TestHelpers::Dpop.generate_key('ES256') }

  def expect_refused(message, &)
    expect(&).to raise_error(Kiosk::Server::Errors::BadRequest, message)
  end

  def accept_es256 = Kiosk.configure { |c| c.assistant_algorithms = %w[EdDSA ES256] }

  it 'accepts EdDSA alone by default' do
    expect(described_class.algorithms).to eq(%w[EdDSA])
  end

  it 'gives the RFC 8037 public members of an Ed25519 key' do
    expect(jwk).to eq(crv: 'Ed25519', kty: 'OKP', x: Base64.urlsafe_encode64(agent_key.raw_public_key, padding: false))
  end

  it 'loads the public key of a one-key JWK Set, with string or symbol members' do
    expect(described_class.from_jwks('keys' => [jwk.transform_keys(&:to_s)]).public_to_pem).to eq(agent_pem)
    expect(described_class.from_jwks(keys: [jwk]).public_to_pem).to eq(agent_pem)
  end

  it 'ignores the members kid, use and alg' do
    key = described_class.from_jwk(jwk.merge(kid: 'k', use: 'sig', alg: 'EdDSA'))
    expect(described_class.thumbprint(key)).to eq(agent_jkt)
  end

  it 'refuses a JWK Set with no key or with two keys' do
    expect_refused(/exactly one key/) { described_class.from_jwks('keys' => []) }
    expect_refused(/exactly one key/) { described_class.from_jwks('keys' => [jwk, jwk]) }
    expect_refused(/exactly one key/) { described_class.from_jwks(nil) }
  end

  it 'refuses a JWK with a private member' do
    expect_refused(/private member/) { described_class.from_jwk(jwk.merge(d: 'AQAB')) }
  end

  it 'refuses an RSA key, a key on another curve, and what is not a JWK' do
    expect_refused(/not an Ed25519 key/) { described_class.from_jwk(kty: 'RSA', n: 'sXch', e: 'AQAB') }
    expect_refused(/curve of an OKP key is Ed25519/) { described_class.from_jwk(jwk.merge(crv: 'Ed448')) }
    expect_refused(/not a valid OKP public key/) { described_class.from_jwk(jwk.merge(x: 'AQAB')) }
    expect_refused(/not a JWK object/) { described_class.from_jwk('OKP') }
  end

  it 'refuses a P-256 key at an operator that does not accept ES256, and says what it accepts' do
    expect_refused(/not an Ed25519 key/) { described_class.from_jwk(described_class.to_jwk(p256)) }
    expect_refused(/not an Ed25519 key/) { described_class.from_pem(p256.public_to_pem) }
  end

  context 'when the operator accepts ES256' do
    before { accept_es256 }

    it 'loads a P-256 key, which signs ES256, and still an Ed25519 key' do
      key = described_class.from_jwk(described_class.to_jwk(p256))
      expect([described_class.algorithm(key), described_class.thumbprint(key)]).to eq(['ES256', Kiosk::TestHelpers::Dpop.thumbprint(p256)])
      expect(described_class.algorithm(described_class.from_jwk(jwk))).to eq('EdDSA')
    end

    it 'names both key types in its hint, and refuses a key on another EC curve' do
      expect(described_class.hint).to include('"kty":"EC","crv":"P-256"')
      expect_refused(/curve of an EC key is P-256/) { described_class.from_jwk(described_class.to_jwk(p256).merge(crv: 'P-384')) }
    end
  end

  it 'refuses a private key as a PEM, a PEM that is not a key, and an RSA PEM' do
    expect_refused(/private key/) { described_class.from_pem(agent_key.private_to_pem) }
    expect_refused(/not a valid public key/) { described_class.from_pem('PEM') }
    expect_refused(/not an Ed25519 key/) { described_class.from_pem(OpenSSL::PKey::RSA.generate(2048).public_to_pem) }
  end

  it 'gives the RFC 7638 thumbprint and the stored PEM form' do
    expect(described_class.thumbprint(agent_key)).to eq(agent_jkt)
    expect(described_class.to_pem(agent_key)).to eq(agent_pem.strip)
  end
end
