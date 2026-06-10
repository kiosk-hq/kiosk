# frozen_string_literal: true

require "openssl"

RSpec.describe Kiosk::Server::SigningKey do
  # Generating an RSA 2048 key takes ~100ms; cache one for the whole file.
  let(:rsa)         { OpenSSL::PKey::RSA.generate(2048) }
  let(:signing_key) { described_class.new(rsa) }

  describe ".generate" do
    it "produces a SigningKey carrying a private key" do
      key = described_class.generate
      expect(key).to be_a(described_class)
      expect(key).to be_private
      expect(key.rsa.n.num_bits).to be >= 2048
    end

    it "accepts a `bits:` override (still ≥ minimum)" do
      key = described_class.generate(bits: 3072)
      expect(key.rsa.n.num_bits).to eq(3072)
    end
  end

  describe ".from_pem" do
    it "round-trips through PEM serialisation" do
      pem = rsa.to_pem
      key = described_class.from_pem(pem)
      expect(key.kid).to eq(signing_key.kid)
    end

    it "accepts a public-only PEM (verifier role)" do
      pub_pem = rsa.public_key.to_pem
      key = described_class.from_pem(pub_pem)
      expect(key).not_to be_private
    end
  end

  describe ".new validation" do
    it "rejects a non-RSA argument" do
      expect { described_class.new("not a key") }
        .to raise_error(ArgumentError, /RSA/)
    end

    it "rejects an undersized RSA key" do
      undersized = OpenSSL::PKey::RSA.generate(1024)
      expect { described_class.new(undersized) }
        .to raise_error(ArgumentError, /minimum is 2048/)
    end
  end

  describe "#kid (RFC 7638 thumbprint)" do
    it "is the same for two SigningKey instances over the same underlying key" do
      pub_only = described_class.from_pem(rsa.public_key.to_pem)
      expect(pub_only.kid).to eq(signing_key.kid)
    end

    it "is base64url with no padding" do
      expect(signing_key.kid).to match(/\A[A-Za-z0-9_-]+\z/)
    end

    it "differs for distinct keys" do
      other = described_class.generate
      expect(other.kid).not_to eq(signing_key.kid)
    end
  end

  describe "#to_jwk" do
    let(:jwk) { signing_key.to_jwk }

    it "has the required RSA-public members" do
      expect(jwk.keys).to include(:kty, :use, :alg, :kid, :n, :e)
    end

    it "advertises kty=RSA, use=sig, alg=RS256" do
      expect(jwk[:kty]).to eq("RSA")
      expect(jwk[:use]).to eq("sig")
      expect(jwk[:alg]).to eq("RS256")
    end

    it "encodes n and e as base64url without padding" do
      expect(jwk[:n]).to match(/\A[A-Za-z0-9_-]+\z/)
      expect(jwk[:e]).to match(/\A[A-Za-z0-9_-]+\z/)
    end

    it "never leaks private parameters (d, p, q, …)" do
      expect(jwk.keys).not_to include(:d, :p, :q, :dp, :dq, :qi)
    end

    it "carries the same kid as #kid" do
      expect(jwk[:kid]).to eq(signing_key.kid)
    end
  end

  describe "#to_pem" do
    it "exports a private PEM that round-trips" do
      pem = signing_key.to_pem
      expect(pem).to include("BEGIN RSA PRIVATE KEY").or include("BEGIN PRIVATE KEY")
      restored = described_class.from_pem(pem)
      expect(restored.kid).to eq(signing_key.kid)
    end

    it "raises when the instance is public-only" do
      pub_only = described_class.from_pem(rsa.public_key.to_pem)
      expect { pub_only.to_pem }.to raise_error(/public-only/)
    end
  end
end
