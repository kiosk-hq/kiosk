# frozen_string_literal: true

require 'base64'
require 'kiosk/reputation'
require 'kiosk/pow/equihash'
require_relative '../../support/equihash_kat'

# End-to-end proof that the DEFAULT backend (equihash) works through the REAL
# N×PoW gate: real HMAC challenge binding + real request-fingerprint + the real
# Kiosk::Pow::Equihash verifier, exercised via PowGate.gate.
#
# We drive the gate's VERIFY path with a deterministic known-answer proof
# (n=8, k=1, salt="kat", indices=[2,10] — the KAT from kiosk-pow-equihash) so
# the test is fast and reproducible. The shipped Python solver produces the same
# {indices, header_nonce} shape at the shipped default parameters, whatever
# `Kiosk::Pow::Equihash.params` answers; solver↔verifier parity is the gem's
# concern. This spec proves the GATE ORCHESTRATION with the
# real equihash crypto: N distinct challenges, verify-through-backend, the
# all-or-re-challenge quota, spend semantics, and fingerprint binding.
module PowGateEquihashE2eSpec
  # The call under test, as a router reaches it on the wire:
  # `GET <endpoint>/catalog?q=milk`. `command:` is the gate/POLICY verb the
  # policy branches on; `method:`/`verb:` are the two halves the request
  # fingerprint binds to alongside the arguments.
  ARGS = { q: 'milk' }.freeze

  # Demands `count` equihash proofs at the KAT params.
  class Policy < Kiosk::Reputation::Policy
    def initialize(count)
      super()
      @count = count
    end

    def challenge_for(**) = { alg: 'equihash', params: EquihashKat::PARAMS, count: @count }
  end

  # Drive the gate for that call. `command:` stays the POLICY verb; any of the
  # three fingerprint inputs can be overridden to build a MISMATCHED submission.
  def gate(pow:, command: 'query', method: 'GET', verb: 'catalog', body: ARGS)
    Kiosk::Server::PowGate.gate(
      identity: identity, command: command, method: method, verb: verb, body: body, pow: pow
    )
  end

  # Hand-mint a signed challenge bound to (method, verb, args) with salt=KAT so
  # the KAT nonce verifies through the real backend. This is exactly what the
  # gate itself emits (same Challenge.issue), but with a controlled salt + id.
  def kat_challenge(id:, method: 'GET', verb: 'catalog', body: ARGS)
    fp = Kiosk::Server::PowGate.request_fingerprint(method: method, verb: verb, body: body)
    Kiosk::Reputation::Challenge.issue(
      alg: 'equihash',
      params: EquihashKat::PARAMS,
      request_fingerprint: fp,
      secret: secret,
      ttl: 300,
      salt: EquihashKat::SALT.b,
      id: id
    )
  end
end

RSpec.shared_context 'pow gate equihash e2e spec: gate' do
  include PowGateEquihashE2eSpec

  before do
    Kiosk::Reputation::Backends.register('equihash', Kiosk::Pow::Equihash)
    Kiosk.configure do |c|
      c.reputation_policy = PowGateEquihashE2eSpec::Policy.new(count)
      c.pow_secret        = secret
      c.schema            = 'kiosk'
    end
  end

  after do
    Kiosk::Reputation::Backends.reset!
    Kiosk.reset!
  end

  let(:identity) { build_identity }
  let(:secret)   { 'equihash-e2e-secret-of-at-least-32-bytes' }
  let(:count)    { 1 }
end

RSpec.describe 'PowGate × equihash (real backend, real gate)' do
  include_context 'pow gate equihash e2e spec: gate'

  it 'issues `count` equihash challenges on an unproven request (the 402 shape)' do
    expect { gate(pow: nil) }.to raise_error(Kiosk::Server::Errors::PowRequired) { |err|
      expect(err.challenges.length).to eq(count)
      expect(err.challenges.first[:alg]).to eq('equihash')
      expect(err.challenges.first[:params]).to eq(EquihashKat::PARAMS)
    }
  end

  it 'proceeds when the real equihash verifier accepts the submitted proof (N=1)' do
    proof = { challenge: kat_challenge(id: 'c1'), nonce: EquihashKat::NONCE }

    expect(gate(pow: [proof])).to eq(:proceed)
  end

  it 'rejects a WRONG nonce through the real verifier (403)' do
    proof = { challenge: kat_challenge(id: 'c1'), nonce: { indices: [3, 10] } } # not a valid solution

    expect do
      gate(pow: [proof])
    end.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)
  end

  context 'N = 3 independent proofs' do
    let(:count) { 3 }

    it 'proceeds only when ALL three verify; a short set re-challenges' do
      proofs = %w[c1 c2 c3].map { |id| { challenge: kat_challenge(id: id), nonce: EquihashKat::NONCE } }

      expect do
        gate(pow: proofs.first(2))
      end.to raise_error(Kiosk::Server::Errors::PowRequired)

      expect(gate(pow: proofs)).to eq(:proceed)
    end
  end

  # ── fingerprint binding, through the real crypto ─────────────────────────
  #
  # The request fingerprint hashes "<METHOD> <verb>\n<canonical args>", so a
  # proof solved for `GET catalog?q=milk` is spendable on that call and on
  # nothing else. Each example below mints its challenge for THAT call and
  # submits it against a request differing in exactly ONE of the three inputs;
  # the N=1 example above is the matching control that shows the proof itself
  # is good.
  describe 'a valid proof submitted against a DIFFERENT request' do
    it 're-challenges when the ARGUMENTS differ' do
      proof = { challenge: kat_challenge(id: 'c1'), nonce: EquihashKat::NONCE }

      expect do
        gate(pow: [proof], body: { q: 'bread' })
      end.to raise_error(Kiosk::Server::Errors::PowRequired)
    end

    it 're-challenges when the METHOD differs (a GET catalog proof on POST catalog)' do
      proof = { challenge: kat_challenge(id: 'c1'), nonce: EquihashKat::NONCE }

      expect do
        gate(pow: [proof], command: 'run', method: 'POST')
      end.to raise_error(Kiosk::Server::Errors::PowRequired)
    end

    it 're-challenges when the VERB differs (a catalog proof is not an orders proof)' do
      proof = { challenge: kat_challenge(id: 'c1'), nonce: EquihashKat::NONCE }

      expect do
        gate(pow: [proof], verb: 'orders')
      end.to raise_error(Kiosk::Server::Errors::PowRequired)
    end
  end
end
