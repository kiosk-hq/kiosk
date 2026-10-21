# frozen_string_literal: true

require 'openssl'

RSpec.describe Kiosk::Server::SigningKey do
  let(:ed25519)     { OpenSSL::PKey.generate_key('ED25519') }
  let(:signing_key) { described_class.new(ed25519) }

  describe '.generate' do
    it 'produces a SigningKey carrying a private Ed25519 key' do
      key = described_class.generate
      expect([key.private?, key.key.oid]).to eq([true, 'ED25519'])
    end
  end

  describe '.from_pem' do
    it 'round-trips through PEM serialisation' do
      expect(described_class.from_pem(ed25519.private_to_pem).kid).to eq(signing_key.kid)
    end

    it 'accepts a public-only PEM (verifier role)' do
      expect(described_class.from_pem(ed25519.public_to_pem)).not_to be_private
    end

    it 'refuses a PEM that is not a key, and names the command that makes one' do
      expect { described_class.from_pem('PEM') }.to raise_error(ArgumentError, /openssl genpkey -algorithm ed25519/)
    end
  end

  describe '.new validation' do
    it 'refuses an RSA key and a P-256 key, and names the command that makes an Ed25519 key' do
      [OpenSSL::PKey::RSA.generate(2048), OpenSSL::PKey::EC.generate('prime256v1')].each do |key|
        expect { described_class.new(key) }.to raise_error(ArgumentError, /Ed25519.*openssl genpkey -algorithm ed25519/)
      end
    end

    it 'refuses what is not a key' do
      expect { described_class.new('not a key') }.to raise_error(ArgumentError, /Ed25519/)
    end
  end

  describe '#kid (RFC 7638 thumbprint)' do
    it 'is the same for two SigningKey instances over the same underlying key' do
      expect(described_class.from_pem(ed25519.public_to_pem).kid).to eq(signing_key.kid)
    end

    it 'is base64url with no padding' do
      expect(signing_key.kid).to match(/\A[A-Za-z0-9_-]{43}\z/)
    end

    it 'differs for distinct keys' do
      expect(described_class.generate.kid).not_to eq(signing_key.kid)
    end
  end

  describe '#to_jwk' do
    let(:jwk) { signing_key.to_jwk }

    it 'has the RFC 8037 public members, use sig, alg EdDSA and the kid, and nothing else' do
      expect(jwk).to eq(kty: 'OKP', crv: 'Ed25519', x: Base64.urlsafe_encode64(ed25519.raw_public_key, padding: false),
                        use: 'sig', alg: 'EdDSA', kid: signing_key.kid)
    end
  end

  describe '#to_pem' do
    it 'exports a private PEM that round-trips' do
      pem = signing_key.to_pem
      expect(pem).to include('BEGIN PRIVATE KEY')
      expect(described_class.from_pem(pem).kid).to eq(signing_key.kid)
    end

    it 'raises when the instance is public-only' do
      pub_only = described_class.from_pem(ed25519.public_to_pem)
      expect { pub_only.to_pem }.to raise_error(/public-only/)
    end
  end
end
