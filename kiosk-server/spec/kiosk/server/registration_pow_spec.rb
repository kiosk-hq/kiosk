# frozen_string_literal: true

require 'base64'
require 'kiosk/reputation'
require 'kiosk/pow/equihash'
require_relative '../../support/equihash_kat'

module RegistrationPowSpec
  PEM = "-----BEGIN PUBLIC KEY-----\nMFkwE... (test)\n-----END PUBLIC KEY-----"

  def pem = PEM

  def configure(count:)
    Kiosk.configure do |c|
      c.registration_pow_count  = count
      c.registration_pow_params = EquihashKat::PARAMS
      c.pow_secret              = secret
    end
  end

  # Configure a registration toll of one challenge at `params`.
  def configure_at(params)
    Kiosk.configure do |c|
      c.registration_pow_count  = 1
      c.registration_pow_params = params
      c.pow_secret              = secret
    end
  end

  # A KAT challenge bound to the register fingerprint, exactly what the gate
  # itself emits: SHA256("<METHOD> <verb>\n<canonical args>"), here
  # `POST auth/register` over the public key being registered.
  def kat_challenge(id:, pem: PEM)
    fp = Kiosk::Server::PowGate.request_fingerprint(method: 'POST', verb: 'auth/register',
                                                    body: { public_key: pem })
    Kiosk::Reputation::Challenge.issue(
      alg: 'equihash', params: EquihashKat::PARAMS, request_fingerprint: fp,
      secret: secret, ttl: 300, salt: 'kat'.b, id: id
    )
  end

  def trivial_proof(id:)
    { challenge: kat_challenge(id: id), nonce: EquihashKat::NONCE }
  end
end

RSpec.shared_context 'registration pow spec: equihash backend' do
  include RegistrationPowSpec

  before do
    Kiosk::Reputation::Backends.register('equihash', Kiosk::Pow::Equihash)
  end

  after do
    Kiosk::Reputation::Backends.reset!
    Kiosk.reset!
  end

  let(:secret) { 'registration-pow-secret-at-least-32-bytes' }
end

# Registration PoW gate — the SAME equihash machinery as the reputation gate,
# applied at /auth/register to price fresh identity minting. Driven with the
# kiosk-pow-equihash known-answer proof (n=8, k=1) so it is fast and real.
RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  it 'is a no-op when registration_pow_count is 0 (default)' do
    expect(Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: nil)).to be_nil
  end

  it 'demands `count` challenges (402) when no proof is submitted' do
    configure(count: 1)
    expect do
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: nil)
    end.to raise_error(Kiosk::Server::Errors::PowRequired) { |e|
      expect(e.challenges.length).to eq(1)
      expect(e.challenges.first[:alg]).to eq('equihash')
    }
  end

  it 'proceeds when the real verifier accepts the proof' do
    configure(count: 1)
    proof = { challenge: kat_challenge(id: 'r1'), nonce: EquihashKat::NONCE }
    expect(
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: { proofs: [proof] })
    ).to be_nil
  end
end

RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  it 'rejects a WRONG nonce (403), with no principal to penalise' do
    configure(count: 1)
    proof = { challenge: kat_challenge(id: 'r1'), nonce: { indices: [3, 10] } }
    expect do
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: { proofs: [proof] })
    end.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)
  end
end

RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  it 'binds proofs to the public key (a proof for another key re-challenges)' do
    configure(count: 1)
    other = { challenge: kat_challenge(id: 'r1', pem: "-----BEGIN PUBLIC KEY-----\nOTHER\n-----END PUBLIC KEY-----"),
              nonce: EquihashKat::NONCE }
    expect do
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: { proofs: [other] })
    end.to raise_error(Kiosk::Server::Errors::PowRequired)
  end

  # The request fingerprint binds the toll to the CALL, not only to its
  # arguments: the registration challenge is minted for `POST auth/register`,
  # so a challenge carrying the same public key under any other method/verb
  # pair is not spendable here even though its HMAC is genuinely ours.
  it 'binds proofs to POST auth/register (the same key under another call re-challenges)' do
    configure(count: 1)
    elsewhere_fp = Kiosk::Server::PowGate.request_fingerprint(
      method: 'GET', verb: 'auth/register', body: { public_key: pem }
    )
    elsewhere = Kiosk::Reputation::Challenge.issue(
      alg: 'equihash', params: EquihashKat::PARAMS, request_fingerprint: elsewhere_fp,
      secret: secret, ttl: 300, salt: 'kat'.b, id: 'r-elsewhere'
    )

    expect do
      Kiosk::Server::RegistrationPow.gate(
        public_key_pem: pem, pow: { proofs: [{ challenge: elsewhere, nonce: EquihashKat::NONCE }] }
      )
    end.to raise_error(Kiosk::Server::Errors::PowRequired)
  end
end

RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  it 'raises ConfigurationError when count > 0 but pow_secret is missing' do
    Kiosk.configure do |c|
      c.registration_pow_count  = 1
      c.registration_pow_params = EquihashKat::PARAMS
    end
    expect do
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: nil)
    end.to raise_error(Kiosk::Server::Errors::ConfigurationError, /pow_secret/)
  end
end

# ── Refuse to MINT a challenge no proof could satisfy ────────────────────────
#
# A degenerate (n, k) would make the client burn a real solve and then get a
# 403 about a correct proof. So the gate asks the backend first, and a
# difficulty it refuses is a ConfigurationError naming the setting, the same
# way a missing pow_secret is.
RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  {
    'n = 0 (every leaf is the integer 0)' => { n: 0, k: 7 },
    'negative k (the solution disappears)' => { n: 168, k: -5 },
    'zero bits per level' => { n: 8, k: 8 }
  }.each do |label, bad_params|
    it "raises ConfigurationError instead of minting a challenge at #{label}" do
      Kiosk.configure do |c|
        c.registration_pow_count  = 1
        c.registration_pow_params = bad_params
        c.pow_secret              = secret
      end
      expect do
        Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: nil)
      end.to raise_error(Kiosk::Server::Errors::ConfigurationError,
                         /registration_pow_params/)
    end
  end
end

RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  it 'names the algorithm and the offending parameters in the message' do
    configure_at({ n: 0, k: 7 })
    expect do
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: nil)
    end.to raise_error(Kiosk::Server::Errors::ConfigurationError, /equihash.*n.*0/m)
  end

  it 'does not mint anything — the raise replaces the 402, it does not follow it' do
    # The point of moving the check to mint time: the client never receives a
    # challenge it cannot use. PowRequired carries the challenges, so if one
    # were issued this would raise PowRequired rather than ConfigurationError.
    configure_at({ n: 0, k: 7 })
    expect(Kiosk::Reputation::Challenge).not_to receive(:issue)
    expect do
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: nil)
    end.to raise_error(Kiosk::Server::Errors::ConfigurationError)
  end

  it 'still accepts the shipped default parameters — the accepted set is unchanged' do
    configure(count: 1)
    expect do
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: nil)
    end.to raise_error(Kiosk::Server::Errors::PowRequired)
  end
end

# /auth/register runs this gate UNAUTHENTICATED, BEFORE PopVerifier, so one
# free challenge must not fuel unlimited garbage-proof verifies. The atomic
# claim consumes the challenge id BEFORE the verify, so a replay of the same id
# gets a re-challenge (402) and never reaches the equihash verify again.
RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  it 'consumes the challenge id on a bad proof so a replay does not re-verify' do
    configure(count: 1)
    bad = { challenge: kat_challenge(id: 'r1'), nonce: { indices: [3, 10] } }

    verify_calls = 0
    allow(Kiosk::Reputation::Challenge).to receive(:verify).and_wrap_original do |orig, **kw|
      verify_calls += 1
      orig.call(**kw)
    end

    # First bad submission → a real 403; the id is now consumed.
    expect do
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: { proofs: [bad] })
    end.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)

    # Replay of the SAME challenge id → re-challenge (402), NOT another 403, and
    # NO second verify (the claim short-circuits before the hash loop).
    expect do
      Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: { proofs: [bad] })
    end.to raise_error(Kiosk::Server::Errors::PowRequired)

    expect(verify_calls).to eq(1)
  end
end

# The gate re-derives the demanded alg/params from live config on every
# verify, so an HMAC-VALID challenge is honoured only at the difficulty the
# server demands now. The examples submit the SAME proof (real secret, real
# register fingerprint, live exp, a nonce that solves it at n=8 k=1) against
# different server configs. Only the params differ.
RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  describe 'server-side parameter re-derivation (K-541)' do
    it 'accepts the trivial proof while the server itself demands n=8 k=1' do
      configure_at(EquihashKat::PARAMS)
      expect(
        Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: { proofs: [trivial_proof(id: 'k541-ok')] })
      ).to be_nil
    end
  end
end

RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  describe 'server-side parameter re-derivation (K-541)' do
    it 'REJECTS that same proof once the server demands harder params' do
      configure_at({ n: 96, k: 5 })

      # A valid signature alone must not set the difficulty.
      expect do
        Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: { proofs: [trivial_proof(id: 'k541-stale')] })
      end.to raise_error(Kiosk::Server::Errors::PowRequired) { |e|
        # Re-challenged at the CURRENT difficulty, not the one it asked for.
        expect(e.challenges.first[:params]).to eq({ n: 96, k: 5 })
      }
    end

    it 'is a re-challenge, not bad faith: the off-spec id is released, not burnt' do
      configure_at({ n: 96, k: 5 })
      expect do
        Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: { proofs: [trivial_proof(id: 'k541-rel')] })
      end.to raise_error(Kiosk::Server::Errors::PowRequired)

      # An honest client holding a pre-raise challenge must not have its id
      # burnt (and a forger must not be able to poison the spent store).
      expect(Kiosk.configuration.pow_spent_store.spent?('k541-rel')).to be(false)
    end
  end
end

RSpec.describe Kiosk::Server::RegistrationPow do
  include_context 'registration pow spec: equihash backend'

  describe 'server-side parameter re-derivation (K-541)' do
    it 'never spends a backend eval on an off-spec challenge' do
      configure_at({ n: 96, k: 5 })
      expect(Kiosk::Pow::Equihash).not_to receive(:verify)
      expect do
        Kiosk::Server::RegistrationPow.gate(public_key_pem: pem, pow: { proofs: [trivial_proof(id: 'k541-nohash')] })
      end.to raise_error(Kiosk::Server::Errors::PowRequired)
    end
  end

  it 'rejects the removed SHA256 registration_difficulty knob' do
    expect do
      Kiosk.configure { |c| c.registration_difficulty = 20 }
    end.to raise_error(ArgumentError, /Equihash/)
  end
end
