# frozen_string_literal: true

require 'kiosk/test_helpers/assistant'
require 'kiosk/test_helpers/kyc'
require 'kiosk/server'

KycSpecOperator = Struct.new(:kyc_provider, :kyc_issuer, :kyc_public_key, :kyc_audience)

# An operator configuration that the helper replaces for the length of each
# example, then puts back. The stub comes before the include, because the
# helper's own hooks read the configuration.
RSpec.shared_context 'with a KYC operator' do
  let(:configuration) { KycSpecOperator.new(:brokers_provider, 'https://broker.example', :brokers_key, 'skooti') }
  let(:rider) { Kiosk::TestHelpers::Assistant::Principal.new(agent_id: 'a1', user_id: 'u1', token: 'tok', rsa_key: nil) }
  let(:customer) { Struct.new(:principal).new(rider) }
  let(:callback_url) { 'http://127.0.0.1:3001/kiosk/kyc/callback' }

  before { allow(Kiosk).to receive(:configuration).and_return(configuration) }
  after { expect(configuration.to_a).to eq([:brokers_provider, 'https://broker.example', :brokers_key, 'skooti']) }

  include Kiosk::TestHelpers::Kyc

  def verified(jws)
    JWT.decode(jws, Kiosk.configuration.kyc_public_key, true,
               algorithm: 'RS256', iss: Kiosk.configuration.kyc_issuer, verify_iss: true).first
  end
end

RSpec.describe Kiosk::TestHelpers::Kyc do
  include_context 'with a KYC operator'

  it 'stands in for the provider, issuer and key for the length of the test' do
    expect(configuration.kyc_provider).to be_a(Kiosk::KycProviders::Base)
    expect(configuration.kyc_issuer).to eq(described_class::ISSUER)
  end

  it 'signs an attestation for the principal, addressed to this operator' do
    expect(verified(kyc_attestation(rider, age_over_18: true))) # rubocop:disable Naming/VariableNumber -- age_over_18 is the published KYC claim name.
      .to include('sub' => 'u1', 'aud' => 'skooti', 'level' => 'verified', 'attributes' => { 'age_over_18' => true })
  end

  it 'signs claims the published kyc.schema.json accepts as an attestation, and it refuses another level' do
    schema = Kiosk::Server::RequestValidation::Schemas.wire('kyc.schema.json#/$defs/attestation')
    claims = verified(kyc_attestation(rider, licence_a: true))
    expect(schema.validate(claims).to_a).to be_empty
    expect(schema.valid?(claims.merge('level' => 'unverified'))).to be(false)
  end

  it 'refuses a customer who opened no check' do
    stranger = Struct.new(:principal).new(rider.with(user_id: 'u2'))
    expect { the_verification_service_confirms(stranger) }.to raise_error(ArgumentError, /"u2"/)
  end

  describe 'callback delivery' do
    it 'delivers a passed check to the callback the engine gave it' do
      opened = configuration.kyc_provider.open_verification(subject: 'u1', claims: %w[licence_a], audience: 'skooti', callback_url:)
      callback = stub_request(:post, callback_url).to_return(json_return(200, 'ok' => true))

      jws = the_verification_service_confirms(customer, licence_a: true)

      expect(callback.with { JSON.parse(it.body) == { 'request_id' => opened[:request_id], 'nonce' => opened[:nonce], 'kyc_jws' => jws } })
        .to have_been_requested
      expect(verified(jws)).to include('sub' => 'u1', 'attributes' => { 'licence_a' => true })
    end

    it 'says so when the engine refuses the callback' do
      configuration.kyc_provider.open_verification(subject: 'u1', claims: [], audience: 'skooti', callback_url:)
      stub_request(:post, callback_url).to_return(problem_return('forbidden', status: 403))

      expect { the_verification_service_confirms(customer) }.to raise_error(/refused the KYC callback: 403/)
    end
  end
end
