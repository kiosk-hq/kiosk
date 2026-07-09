# frozen_string_literal: true

require "base64"
require "kiosk/reputation"
require "kiosk/pow/equihash"

# Registration PoW gate — the SAME equihash machinery as the reputation gate,
# applied at /auth/register to price fresh identity minting. Driven with the
# kiosk-pow-equihash known-answer proof (n=8, k=1) so it is fast and real.
RSpec.describe Kiosk::Server::RegistrationPow do
  KAT_PARAMS = { n: 8, k: 1 }.freeze
  KAT_NONCE  = { indices: [2, 10] }.freeze
  PEM        = "-----BEGIN PUBLIC KEY-----\nMFkwE... (test)\n-----END PUBLIC KEY-----"

  before(:each) do
    Kiosk::Reputation::Backends.register("equihash", Kiosk::Pow::Equihash)
  end

  after(:each) do
    Kiosk::Reputation::Backends.reset!
    Kiosk.reset!
  end

  let(:secret) { "registration-pow-secret" }

  def configure(count:)
    Kiosk.configure do |c|
      c.registration_pow_count  = count
      c.registration_pow_params = KAT_PARAMS
      c.pow_secret              = secret
    end
  end

  # A KAT challenge bound to the register fingerprint (public key), exactly what
  # the gate itself emits.
  def kat_challenge(id:, pem: PEM)
    fp = Kiosk::Server::PowGate.request_fingerprint(command: "auth/register", body: { public_key: pem })
    Kiosk::Reputation::Challenge.issue(
      alg: "equihash", params: KAT_PARAMS, request_fingerprint: fp,
      secret: secret, ttl: 300, salt: "kat".b, id: id,
    )
  end

  it "is a no-op when registration_pow_count is 0 (default)" do
    expect(Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: nil)).to be_nil
  end

  it "demands `count` challenges (402) when no proof is submitted" do
    configure(count: 1)
    expect {
      Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: nil)
    }.to raise_error(Kiosk::Server::Errors::PowRequired) { |e|
      expect(e.challenges.length).to eq(1)
      expect(e.challenges.first[:alg]).to eq("equihash")
    }
  end

  it "proceeds when the real verifier accepts the proof" do
    configure(count: 1)
    proof = { challenge: kat_challenge(id: "r1"), nonce: KAT_NONCE }
    expect(
      Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: { proofs: [proof] }),
    ).to be_nil
  end

  it "rejects a WRONG nonce (403), with no principal to penalise" do
    configure(count: 1)
    proof = { challenge: kat_challenge(id: "r1"), nonce: { indices: [3, 10] } }
    expect {
      Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: { proofs: [proof] })
    }.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)
  end

  it "binds proofs to the public key (a proof for another key re-challenges)" do
    configure(count: 1)
    other = { challenge: kat_challenge(id: "r1", pem: "-----BEGIN PUBLIC KEY-----\nOTHER\n-----END PUBLIC KEY-----"),
              nonce: KAT_NONCE }
    expect {
      Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: { proofs: [other] })
    }.to raise_error(Kiosk::Server::Errors::PowRequired)
  end

  it "raises ConfigurationError when count > 0 but pow_secret is missing" do
    Kiosk.configure do |c|
      c.registration_pow_count  = 1
      c.registration_pow_params = KAT_PARAMS
    end
    expect {
      Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: nil)
    }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /pow_secret/)
  end

  it "rejects the removed SHA256 registration_difficulty knob" do
    expect {
      Kiosk.configure { |c| c.registration_difficulty = 20 }
    }.to raise_error(ArgumentError, /Equihash/)
  end
end
