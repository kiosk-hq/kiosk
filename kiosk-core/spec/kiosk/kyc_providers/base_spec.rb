# frozen_string_literal: true

require 'openssl'

RSpec.describe Kiosk::KycProviders::Base do
  subject(:provider) { described_class.new(issuer: 'https://kyc.example', public_key: key, audience: 'shop') }

  let(:key) { OpenSSL::PKey.generate_key('ED25519') }

  it 'names the issuer, the key and the audience that an attestation is checked against' do
    expect([provider.issuer, provider.public_key, provider.audience]).to eq(['https://kyc.example', key, 'shop'])
  end

  it 'reads the PEM of an Ed25519 public key' do
    from_pem = described_class.new(issuer: 'https://kyc.example', public_key: key.public_to_pem)
    expect(from_pem.public_key.public_to_pem).to eq(key.public_to_pem)
  end

  it 'refuses a key that is not Ed25519' do
    expect { described_class.new(issuer: 'https://kyc.example', public_key: OpenSSL::PKey::RSA.generate(2048).public_to_pem) }
      .to raise_error(ArgumentError, /Ed25519/)
  end

  it 'defaults the audience to the origin being served' do
    unnamed = described_class.new(issuer: 'https://kyc.example', public_key: key)
    expect(Kiosk.with_issuer('https://shop.example') { unnamed.audience }).to eq('https://shop.example')
  end

  it 'opens no verifications' do
    expect(provider.opens_verifications?).to be(false)
    expect { provider.open_verification(subject: 'user-1', claims: %w[age_over_18], callback_url: 'https://shop.example/kiosk/kyc/callback') }
      .to raise_error(NotImplementedError, /open_verification must be implemented/)
  end

  it 'accepts every attestation the engine verified' do
    expect(provider.accepts?({ 'sub' => 'user-1' })).to be(true)
  end

  it 'is configured on Kiosk.configuration.kyc_provider, nil by default' do
    expect(Kiosk::Configuration.new.kyc_provider).to be_nil
  end
end
