# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'socket'

PROVE_SPEC_KEY = OpenSSL::PKey.generate_key('ED25519')

RSpec.shared_context 'with a Prove broker client' do
  subject(:prove) { described_class.new(operator_id: 'shop', intake_secret: 's3cret', public_key: PROVE_SPEC_KEY, url: 'https://broker.example/') }

  let(:sent) { [] }

  # Yields each Net::HTTP the client builds, for the example to stub.
  def on_http(&)
    allow(Net::HTTP).to receive(:new).and_wrap_original do |new, *args|
      new.call(*args).tap(&)
    end
  end

  def answer(code, body)
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new('1.1', code.to_s, '')
    allow(response).to receive(:body).and_return(body.is_a?(String) ? body : JSON.generate(body))
    on_http { |http| allow(http).to receive(:request) { |req| (sent << [http, req]) && response } }
  end

  def open!
    prove.open_verification(subject: 'u-1', claims: %w[age_over_18 licence_a], callback_url: 'https://shop.example/kiosk/kyc/callback')
  end
end

RSpec.describe Kiosk::KycProviders::Prove do
  include_context 'with a Prove broker client'

  it 'is a KycProviders::Base' do
    expect(prove).to be_a(Kiosk::KycProviders::Base)
  end

  it 'accepts only an attestation the broker minted for this operator' do
    expect(prove.accepts?('operator' => 'shop')).to be(true)
    expect(prove.accepts?('operator' => 'other')).to be(false)
    expect(prove.accepts?({})).to be(false)
  end

  it "checks attestations against the broker's issuer, its key and the operator id as the audience" do
    expect([prove.issuer, prove.public_key, prove.audience]).to eq(['https://broker.example', PROVE_SPEC_KEY, 'shop'])
  end

  it "takes the broker's issuer when it differs from the broker's URL, and opens verifications" do
    broker = described_class.new(operator_id: 'shop', intake_secret: 's3cret', public_key: PROVE_SPEC_KEY.public_to_pem,
                                 url: 'http://127.0.0.1:3020', issuer: 'https://kyc.test.local')
    expect([broker.issuer, broker.opens_verifications?]).to eq(['https://kyc.test.local', true])
  end

  it 'refuses to be built without an intake secret' do
    expect { described_class.new(operator_id: 'shop', intake_secret: '', public_key: PROVE_SPEC_KEY) }.to raise_error(ArgumentError)
  end

  describe '#open_verification' do
    it "opens a verification at the broker's intake, asking for the attribute names" do
      answer(201, request_id: 'r-1', verification_url: 'https://broker.example/v/r-1', nonce: 'n-1')

      expect(open!).to eq(request_id: 'r-1', verification_url: 'https://broker.example/v/r-1', nonce: 'n-1')
      http, req = sent.first
      expect([http.address, http.use_ssl?, req.path]).to eq(['broker.example', true, '/verifications'])
      expect(req['Authorization']).to eq('Bearer s3cret')
      expect(JSON.parse(req.body)).to eq(
        'operator_id' => 'shop', 'callback_url' => 'https://shop.example/kiosk/kyc/callback',
        'requested_claims' => %w[age_over_18 licence_a], 'subject_handle' => 'u-1', 'audience' => 'shop'
      )
    end

    it 'raises Unavailable on a refusal, a body that is not JSON, or a body missing a field' do
      [[401, { error: 'no' }], [201, '<html>'], [201, { request_id: 'r-1', nonce: 'n-1' }]].each do |code, body|
        answer(code, body)
        expect { open! }.to raise_error(Kiosk::KycProviders::Unavailable)
      end
    end

    it 'dials an IPv6 literal intake by its bare address' do
      answer(201, request_id: 'r-1', verification_url: 'http://[::1]:3004/v/r-1', nonce: 'n-1')
      broker = described_class.new(operator_id: 'shop', intake_secret: 's3cret', public_key: PROVE_SPEC_KEY, url: 'http://[::1]:3004/')
      broker.open_verification(subject: 'u-1', claims: %w[age_over_18], callback_url: 'https://shop.example/cb')

      http, = sent.first
      expect([http.address, http.port]).to eq(['::1', 3004])
    end

    it 'raises Unavailable when the broker cannot be reached' do
      on_http { |http| allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED) }
      expect { open! }.to raise_error(Kiosk::KycProviders::Unavailable, /could not be reached/)
    end

    it 'raises Unavailable when the broker answers bytes that are not HTTP' do
      server = TCPServer.new('127.0.0.1', 0)
      listener = Thread.new { server.accept.then { |peer| peer.readpartial(4096) && peer.write("garbage\r\n") && peer.close } }
      broker = described_class.new(operator_id: 'shop', intake_secret: 's3cret', public_key: PROVE_SPEC_KEY, url: "http://127.0.0.1:#{server.addr[1]}/")

      expect do
        broker.open_verification(subject: 'u-1', claims: %w[age_over_18], callback_url: 'https://shop.example/cb')
      end.to raise_error(Kiosk::KycProviders::Unavailable, /could not be reached/)
    ensure
      listener&.join(1)
      server&.close
    end
  end
end
