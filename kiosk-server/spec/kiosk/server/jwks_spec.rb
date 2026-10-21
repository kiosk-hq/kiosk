# frozen_string_literal: true

require 'rack/mock'

RSpec.describe Kiosk::Server::Jwks do
  let(:key)  { Kiosk::Server::SigningKey.generate }
  let(:key2) { Kiosk::Server::SigningKey.generate }

  describe '.build' do
    it 'returns a single-key JWKS for one input' do
      doc = described_class.build(keys: [key])
      expect(doc).to eq(keys: [key.to_jwk])
    end

    it 'preserves order for multi-key rotation overlap' do
      doc = described_class.build(keys: [key, key2])
      expect(doc[:keys].pluck(:kid)).to eq([key.kid, key2.kid])
    end

    it 'accepts a single key passed without an array (Array() upcasts)' do
      doc = described_class.build(keys: key)
      expect(doc[:keys].size).to eq(1)
      expect(doc[:keys].first[:kid]).to eq(key.kid)
    end

    it "produces JSON that's parseable and contains only the public JWK fields" do
      json = JSON.generate(described_class.build(keys: [key]))
      parsed = JSON.parse(json, symbolize_names: true)
      jwk = parsed[:keys].first
      expect(jwk.keys).to match_array(%i[kty crv x use alg kid])
    end
  end

  # Operator key rotation (spec Section 4.4): the document holds the current key
  # and, while it is set, the previous one.
  describe Kiosk::Server::JwksController do
    def served_kids
      _, _, body = described_class.action(:show).call(Rack::MockRequest.env_for('/kiosk/.well-known/jwks.json'))
      raw = +''
      body.each { |chunk| raw << chunk }
      JSON.parse(raw).fetch('keys').map { it.fetch('kid') }
    end

    let(:current)  { Kiosk::Server::SigningKey.generate }
    let(:previous) { Kiosk::Server::SigningKey.generate }

    it 'serves the current key alone when no previous key is set' do
      Kiosk.configure { |c| c.signing_key = current }
      expect(served_kids).to eq([current.kid])
    end

    it 'serves the current key first and the previous key after it' do
      Kiosk.configure do |c|
        c.signing_key          = current
        c.previous_signing_key = previous.key.public_to_pem
      end
      expect(served_kids).to eq([current.kid, previous.kid])
    end

    it 'refuses a previous key that is neither a SigningKey nor a PEM' do
      expect { Kiosk.configure { |c| c.previous_signing_key = 42 } }
        .to raise_error(ArgumentError, /previous_signing_key must be a SigningKey or PEM string/)
    end
  end
end
