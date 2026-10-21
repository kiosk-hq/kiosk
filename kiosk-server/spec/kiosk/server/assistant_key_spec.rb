# frozen_string_literal: true

# The assistant's public key: loaded from a JWK or a PEM, held to the bounds,
# and named by its RFC 7638 thumbprint.
RSpec.describe Kiosk::Server::AssistantKey do
  let(:jwk) { described_class.to_jwk(agent_key.public_key) }

  def expect_refused(message, &)
    expect(&).to raise_error(Kiosk::Server::Errors::BadRequest, message)
  end

  it 'lists RS256 as the one signing algorithm' do
    expect(described_class::ALGORITHMS).to eq(%w[RS256])
  end

  it 'loads the public key of a one-key JWK Set, with string or symbol members' do
    expect(described_class.from_jwks('keys' => [jwk]).to_pem).to eq(agent_key.public_key.to_pem)
    expect(described_class.from_jwks(keys: [jwk]).to_pem).to eq(agent_key.public_key.to_pem)
  end

  it 'ignores the members kid, use and alg' do
    key = described_class.from_jwk(jwk.merge(kid: 'k', use: 'sig', alg: 'RS256'))
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

  it 'refuses a key that is not RSA, or not a JWK' do
    expect_refused(/not an RSA key/) { described_class.from_jwk(kty: 'EC', crv: 'P-256', x: 'a', y: 'b') }
    expect_refused(/not a JWK object/) { described_class.from_jwk('RSA') }
    expect_refused(/too small \(0 bits\)/) { described_class.from_jwk(kty: 'RSA', n: '', e: '') }
  end

  it 'refuses a key outside 2048 to 4096 bits' do
    small = OpenSSL::PKey::RSA.generate(1024)
    expect_refused(/too small \(1024 bits\)/) { described_class.from_jwk(described_class.to_jwk(small.public_key)) }
    expect_refused(/too small/) { described_class.from_pem(small.public_key.to_pem) }
  end

  it 'refuses a private key as a PEM, and a PEM that is not a key' do
    expect_refused(/private key/) { described_class.from_pem(agent_key.to_pem) }
    expect_refused(/not a valid RSA public key/) { described_class.from_pem('PEM') }
  end

  it 'gives the RFC 7638 thumbprint and the stored PEM form' do
    expect(described_class.thumbprint(agent_key.public_key)).to eq(agent_jkt)
    expect(described_class.to_pem(agent_key.public_key)).to eq(agent_pem.strip)
  end
end
