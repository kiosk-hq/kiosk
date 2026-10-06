# frozen_string_literal: true

require "json"
require "net/http"

RSpec.describe Kiosk::KycProviders::Prove do
  subject(:prove) { described_class.new(operator_id: "shop", intake_secret: "s3cret", url: "https://broker.example/") }

  let(:sent) { [] }

  def answer(code, body)
    sent = self.sent
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "")
    allow(response).to receive(:body).and_return(body.is_a?(String) ? body : JSON.generate(body))
    allow_any_instance_of(Net::HTTP).to receive(:request) { |http, req| sent << [http, req] && response }
  end

  def open!
    prove.open_verification(subject: "u-1", claims: %w[age_over_18 licence_a], audience: "shop",
                            callback_url: "https://shop.example/kiosk/kyc/callback")
  end

  it "is a KycProviders::Base" do
    expect(prove).to be_a(Kiosk::KycProviders::Base)
  end

  it "opens a verification at the broker's intake, in the broker's claim vocabulary" do
    answer(201, request_id: "r-1", verification_url: "https://broker.example/v/r-1", nonce: "n-1")

    expect(open!).to eq(request_id: "r-1", verification_url: "https://broker.example/v/r-1", nonce: "n-1")
    http, req = sent.first
    expect([http.address, http.use_ssl?, req.path]).to eq(["broker.example", true, "/verifications"])
    expect(req["Authorization"]).to eq("Bearer s3cret")
    expect(JSON.parse(req.body)).to eq(
      "operator_id" => "shop", "callback_url" => "https://shop.example/kiosk/kyc/callback",
      "requested_claims" => ["age_over_18", "licence_category:A"], "subject_handle" => "u-1", "audience" => "shop",
    )
  end

  it "raises Unavailable on a refusal, a body that is not JSON, or a body missing a field" do
    [[401, { error: "no" }], [201, "<html>"], [201, { request_id: "r-1", nonce: "n-1" }]].each do |code, body|
      answer(code, body)
      expect { open! }.to raise_error(Kiosk::KycProviders::Unavailable)
    end
  end

  it "raises Unavailable when the broker cannot be reached" do
    allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(Errno::ECONNREFUSED)
    expect { open! }.to raise_error(Kiosk::KycProviders::Unavailable, /could not be reached/)
  end

  it "accepts only an attestation the broker minted for this operator" do
    expect(prove.accepts?("operator" => "shop")).to be(true)
    expect(prove.accepts?("operator" => "other")).to be(false)
    expect(prove.accepts?({})).to be(false)
  end

  it "refuses to be built without an intake secret" do
    expect { described_class.new(operator_id: "shop", intake_secret: "") }.to raise_error(ArgumentError)
  end

  it "reads the broker's address and issuer from the environment, defaulting to the hosted broker" do
    expect(described_class.issuer).to eq(ENV.fetch("KIOSK_PROVE_ISSUER", described_class::HOSTED))
    expect(described_class.broker_url).to eq(ENV.fetch("KIOSK_PROVE_BROKER_URL", described_class::HOSTED))
  end
end
