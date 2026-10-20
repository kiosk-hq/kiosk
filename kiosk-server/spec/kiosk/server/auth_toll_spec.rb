# frozen_string_literal: true

require 'base64'
require 'kiosk/reputation'
require 'kiosk/pow/equihash'
require_relative '../../support/equihash_kat'

module AuthTollSpec
  PEM = "-----BEGIN PUBLIC KEY-----\nMFkwE... (test)\n-----END PUBLIC KEY-----"

  def pem = PEM

  # The register request's toll: `POST auth/register` over the key being registered.
  def register_toll(pow) = Kiosk::Server::AuthToll.gate(verb: 'auth/register', body: { public_key: pem }, pow: pow)

  def configure(count:)
    Kiosk.configure do |c|
      c.registration_pow_count = count
      c.pow_secret             = secret
    end
  end

  # A toll of one challenge, with the gem's default params stubbed to `params`.
  def configure_at(params)
    allow(Kiosk::Pow::Equihash).to receive(:params).and_return(params)
    configure(count: 1)
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

RSpec.shared_context 'auth toll spec: equihash backend' do
  include AuthTollSpec

  before do
    Kiosk::Reputation::Backends.register('equihash', Kiosk::Pow::Equihash)
    allow(Kiosk::Pow::Equihash).to receive(:params).and_return(EquihashKat::PARAMS)
  end

  after do
    Kiosk::Reputation::Backends.reset!
    Kiosk.reset!
  end

  let(:secret) { 'registration-pow-secret-at-least-32-bytes' }
end

RSpec.describe Kiosk::Server::AuthToll do
  include_context 'auth toll spec: equihash backend'

  it 'is a no-op when registration_pow_count is 0 (default)' do
    expect(register_toll(nil)).to be_nil
  end

  it 'demands `count` challenges (402) when no proof is submitted' do
    configure(count: 1)
    expect do
      register_toll(nil)
    end.to raise_error(Kiosk::Server::Errors::PowRequired) { |e|
      expect(e.challenges.length).to eq(1)
      expect(e.challenges.first[:alg]).to eq('equihash')
    }
  end

  it 'proceeds when the real verifier accepts the proof' do
    configure(count: 1)
    proof = { challenge: kat_challenge(id: 'r1'), nonce: EquihashKat::NONCE }
    expect(
      register_toll([proof])
    ).to be_nil
  end

  it 'rejects a WRONG nonce (403), with no principal to penalise' do
    configure(count: 1)
    proof = { challenge: kat_challenge(id: 'r1'), nonce: { indices: [3, 10] } }
    expect do
      register_toll([proof])
    end.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)
  end

  it 'binds proofs to the public key (a proof for another key re-challenges)' do
    configure(count: 1)
    other = { challenge: kat_challenge(id: 'r1', pem: "-----BEGIN PUBLIC KEY-----\nOTHER\n-----END PUBLIC KEY-----"),
              nonce: EquihashKat::NONCE }
    expect do
      register_toll([other])
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
      register_toll([{ challenge: elsewhere, nonce: EquihashKat::NONCE }])
    end.to raise_error(Kiosk::Server::Errors::PowRequired)
  end

  it 'raises ConfigurationError when count > 0 but pow_secret is missing' do
    Kiosk.configure { |c| c.registration_pow_count = 1 }
    expect do
      register_toll(nil)
    end.to raise_error(Kiosk::Server::Errors::ConfigurationError, /pow_secret/)
  end

  it 'names the algorithm and the offending parameters in the message' do
    configure_at({ n: 0, k: 7 })
    expect do
      register_toll(nil)
    end.to raise_error(Kiosk::Server::Errors::ConfigurationError, /equihash.*n.*0/m)
  end

  it 'does not mint anything — the raise replaces the 402, it does not follow it' do
    # The point of moving the check to mint time: the client never receives a
    # challenge it cannot use. PowRequired carries the challenges, so if one
    # were issued this would raise PowRequired rather than ConfigurationError.
    configure_at({ n: 0, k: 7 })
    allow(Kiosk::Reputation::Challenge).to receive(:issue)
    expect { register_toll(nil) }.to raise_error(Kiosk::Server::Errors::ConfigurationError)
    expect(Kiosk::Reputation::Challenge).not_to have_received(:issue)
  end

  it 'still accepts the shipped default parameters — the accepted set is unchanged' do
    allow(Kiosk::Pow::Equihash).to receive(:params).and_call_original
    configure(count: 1)
    expect do
      register_toll(nil)
    end.to raise_error(Kiosk::Server::Errors::PowRequired)
  end

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
      register_toll([bad])
    end.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)

    # Replay of the SAME challenge id → re-challenge (402), NOT another 403, and
    # NO second verify (the claim short-circuits before the hash loop).
    expect do
      register_toll([bad])
    end.to raise_error(Kiosk::Server::Errors::PowRequired)

    expect(verify_calls).to eq(1)
  end

  describe 'server-side parameter re-derivation (K-541)' do
    it 'accepts the trivial proof while the server itself demands n=8 k=1' do
      configure_at(EquihashKat::PARAMS)
      expect(
        register_toll([trivial_proof(id: 'k541-ok')])
      ).to be_nil
    end

    it 'REJECTS that same proof once the server demands harder params' do
      configure_at({ n: 96, k: 5 })

      # A valid signature alone must not set the difficulty.
      expect do
        register_toll([trivial_proof(id: 'k541-stale')])
      end.to raise_error(Kiosk::Server::Errors::PowRequired) { |e|
        # Re-challenged at the CURRENT difficulty, not the one it asked for.
        expect(e.challenges.first[:params]).to eq({ n: 96, k: 5 })
      }
    end

    it 'is a re-challenge, not bad faith: the off-spec id is released, not burnt' do
      configure_at({ n: 96, k: 5 })
      expect do
        register_toll([trivial_proof(id: 'k541-rel')])
      end.to raise_error(Kiosk::Server::Errors::PowRequired)

      # An honest client holding a pre-raise challenge must not have its id
      # burnt (and a forger must not be able to poison the spent store).
      expect(Kiosk.configuration.pow_spent_store.spent?('k541-rel')).to be(false)
    end

    it 'never spends a backend eval on an off-spec challenge' do
      configure_at({ n: 96, k: 5 })
      allow(Kiosk::Pow::Equihash).to receive(:verify)
      expect { register_toll([trivial_proof(id: 'k541-nohash')]) }.to raise_error(Kiosk::Server::Errors::PowRequired)
      expect(Kiosk::Pow::Equihash).not_to have_received(:verify)
    end
  end
end
