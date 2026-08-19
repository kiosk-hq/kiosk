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

  # A KAT challenge bound to the register fingerprint, exactly what the gate
  # itself emits. Since the 0.4 cutover that fingerprint is §3.4's
  # SHA256("<METHOD> <verb>\n<canonical args>") — here `POST auth/register`
  # over the public key being registered.
  def kat_challenge(id:, pem: PEM)
    fp = Kiosk::Server::PowGate.request_fingerprint(method: "POST", verb: "auth/register",
                                                    body: { public_key: pem })
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

  # §3.4 binds the toll to the CALL, not only to its arguments: the registration
  # challenge is minted for `POST auth/register`, so a challenge carrying the
  # same public key under any other method/verb pair is not spendable here even
  # though its HMAC is genuinely ours.
  it "binds proofs to POST auth/register (the same key under another call re-challenges)" do
    configure(count: 1)
    elsewhere_fp = Kiosk::Server::PowGate.request_fingerprint(
      method: "GET", verb: "auth/register", body: { public_key: PEM },
    )
    elsewhere = Kiosk::Reputation::Challenge.issue(
      alg: "equihash", params: KAT_PARAMS, request_fingerprint: elsewhere_fp,
      secret: secret, ttl: 300, salt: "kat".b, id: "r-elsewhere",
    )

    expect {
      Kiosk::Server::RegistrationPow.gate(
        public_key_pem: PEM, pow: { proofs: [{ challenge: elsewhere, nonce: KAT_NONCE }] },
      )
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

  # K-540: /auth/register runs this gate UNAUTHENTICATED, BEFORE PopVerifier, so
  # a bad proof must not let one free challenge fuel unlimited garbage-proof
  # verifies. The atomic claim (K-542) consumes the challenge id BEFORE the
  # verify, so a replay of the same id is turned away with a re-challenge (402)
  # and never reaches the expensive equihash verify a second time.
  it "consumes the challenge id on a bad proof so a replay does not re-verify" do
    configure(count: 1)
    bad = { challenge: kat_challenge(id: "r1"), nonce: { indices: [3, 10] } }

    verify_calls = 0
    allow(Kiosk::Reputation::Challenge).to receive(:verify).and_wrap_original do |orig, **kw|
      verify_calls += 1
      orig.call(**kw)
    end

    # First bad submission → a real 403; the id is now consumed.
    expect {
      Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: { proofs: [bad] })
    }.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)

    # Replay of the SAME challenge id → re-challenge (402), NOT another 403, and
    # NO second verify (the claim short-circuits before the hash loop).
    expect {
      Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: { proofs: [bad] })
    }.to raise_error(Kiosk::Server::Errors::PowRequired)

    expect(verify_calls).to eq(1)
  end

  # K-541: the gate re-derives the demanded alg/params from live config on every
  # verify, so an HMAC-VALID challenge is honoured only at the difficulty the
  # server currently demands. The two examples below submit the SAME proof —
  # real secret, real register fingerprint, live exp, and a nonce that genuinely
  # solves it at n=8 k=1 — against two server configs. Only the params differ.
  describe "server-side parameter re-derivation (K-541)" do
    def trivial_proof(id:)
      { challenge: kat_challenge(id: id), nonce: KAT_NONCE }
    end

    def configure_at(params)
      Kiosk.configure do |c|
        c.registration_pow_count  = 1
        c.registration_pow_params = params
        c.pow_secret              = secret
      end
    end

    it "accepts the trivial proof while the server itself demands n=8 k=1" do
      configure_at(KAT_PARAMS)
      expect(
        Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: { proofs: [trivial_proof(id: "k541-ok")] }),
      ).to be_nil
    end

    it "REJECTS that same proof once the server demands harder params" do
      configure_at({ n: 96, k: 5 })

      # Before K-541 this returned :proceed: the sig was ours, so the challenge
      # was honoured at whatever difficulty it named — a leaked pow_secret (or
      # a challenge outliving a difficulty raise) turned the toll off silently.
      expect {
        Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: { proofs: [trivial_proof(id: "k541-stale")] })
      }.to raise_error(Kiosk::Server::Errors::PowRequired) { |e|
        # Re-challenged at the CURRENT difficulty, not the one it asked for.
        expect(e.challenges.first[:params]).to eq({ n: 96, k: 5 })
      }
    end

    it "is a re-challenge, not bad faith: the off-spec id is released, not burnt" do
      configure_at({ n: 96, k: 5 })
      expect {
        Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: { proofs: [trivial_proof(id: "k541-rel")] })
      }.to raise_error(Kiosk::Server::Errors::PowRequired)

      # An honest client holding a pre-raise challenge must not have its id
      # burnt (and a forger must not be able to poison the spent store).
      expect(Kiosk.configuration.pow_spent_store.spent?("k541-rel")).to be(false)
    end

    it "never spends a backend eval on an off-spec challenge" do
      configure_at({ n: 96, k: 5 })
      expect(Kiosk::Pow::Equihash).not_to receive(:verify)
      expect {
        Kiosk::Server::RegistrationPow.gate(public_key_pem: PEM, pow: { proofs: [trivial_proof(id: "k541-nohash")] })
      }.to raise_error(Kiosk::Server::Errors::PowRequired)
    end
  end

  it "rejects the removed SHA256 registration_difficulty knob" do
    expect {
      Kiosk.configure { |c| c.registration_difficulty = 20 }
    }.to raise_error(ArgumentError, /Equihash/)
  end
end
