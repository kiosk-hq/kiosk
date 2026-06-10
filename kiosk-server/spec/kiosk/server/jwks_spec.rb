# frozen_string_literal: true

RSpec.describe Kiosk::Server::Jwks do
  let(:key)  { Kiosk::Server::SigningKey.generate }
  let(:key2) { Kiosk::Server::SigningKey.generate }

  describe ".build" do
    it "returns a single-key JWKS for one input" do
      doc = described_class.build(keys: [key])
      expect(doc).to eq(keys: [key.to_jwk])
    end

    it "preserves order for multi-key rotation overlap" do
      doc = described_class.build(keys: [key, key2])
      expect(doc[:keys].map { |jwk| jwk[:kid] }).to eq([key.kid, key2.kid])
    end

    it "accepts a single key passed without an array (Array() upcasts)" do
      doc = described_class.build(keys: key)
      expect(doc[:keys].size).to eq(1)
      expect(doc[:keys].first[:kid]).to eq(key.kid)
    end

    it "produces JSON that's parseable and contains only the public JWK fields" do
      json = JSON.generate(described_class.build(keys: [key]))
      parsed = JSON.parse(json, symbolize_names: true)
      jwk = parsed[:keys].first
      expect(jwk.keys).to match_array(%i[kty use alg kid n e])
    end
  end
end
