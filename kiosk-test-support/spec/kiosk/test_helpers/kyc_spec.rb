# frozen_string_literal: true

require "kiosk/test_helpers/assistant"
require "kiosk/test_helpers/kyc"

RSpec.describe Kiosk::TestHelpers::Kyc do
  operator = Struct.new(:kyc_provider, :kyc_issuer, :kyc_public_key, :kyc_audience)
  configuration = operator.new(:brokers_provider, "https://broker.example", :brokers_key, "skooti")

  before { allow(Kiosk).to receive(:configuration).and_return(configuration) }
  after { expect(configuration.to_a).to eq([:brokers_provider, "https://broker.example", :brokers_key, "skooti"]) }

  include described_class

  let(:rider) { Kiosk::TestHelpers::Assistant::Principal.new(agent_id: "a1", user_id: "u1", token: "tok", rsa_key: nil) }

  def verified(jws)
    JWT.decode(jws, Kiosk.configuration.kyc_public_key, true, algorithm: "RS256", iss: Kiosk.configuration.kyc_issuer,
                                                             verify_iss: true).first
  end

  it "stands in for the provider, issuer and key for the length of the test" do
    expect(configuration.kyc_provider).to be_a(Kiosk::KycProviders::Base)
    expect(configuration.kyc_issuer).to eq(described_class::ISSUER)
  end

  it "signs an attestation for the principal, addressed to this operator" do
    expect(verified(kyc_attestation(rider, age_over_18: true)))
      .to include("sub" => "u1", "aud" => "skooti", "level" => "verified", "attributes" => { "age_over_18" => true })
  end

  it "delivers a passed check to the callback the engine gave it" do
    opened = configuration.kyc_provider.open_verification(subject: "u1", claims: %w[licence_a], audience: "skooti",
                                                          callback_url: "http://127.0.0.1:3001/kiosk/kyc/callback")
    callback = stub_request(:post, "http://127.0.0.1:3001/kiosk/kyc/callback").to_return(json_return(200, "ok" => true))

    jws = the_verification_service_confirms({ "request_id" => opened[:request_id] }, licence_a: true)

    expect(callback.with { JSON.parse(_1.body) == { "request_id" => opened[:request_id], "nonce" => opened[:nonce], "kyc_jws" => jws } })
      .to have_been_requested
    expect(verified(jws)).to include("sub" => "u1", "attributes" => { "licence_a" => true })
  end

  it "says so when the engine refuses the callback" do
    opened = configuration.kyc_provider.open_verification(subject: "u1", claims: [], audience: "skooti",
                                                          callback_url: "http://127.0.0.1:3001/kiosk/kyc/callback")
    stub_request(:post, "http://127.0.0.1:3001/kiosk/kyc/callback").to_return(problem_return("forbidden", status: 403))

    expect { the_verification_service_confirms({ "request_id" => opened[:request_id] }) }.to raise_error(/refused the KYC callback: 403/)
  end

  it "refuses a check it never opened" do
    expect { the_verification_service_confirms({ "request_id" => "nope" }) }.to raise_error(ArgumentError, /"nope"/)
  end
end
