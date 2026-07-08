# frozen_string_literal: true

require "base64"
require "kiosk/reputation"
require "kiosk/pow/equihash"

# End-to-end proof that the DEFAULT backend (equihash) works through the REAL
# N×PoW gate: real HMAC challenge binding + real request-fingerprint + the real
# Kiosk::Pow::Equihash verifier, exercised via PowGate.gate.
#
# We drive the gate's VERIFY path with a deterministic known-answer proof
# (n=8, k=1, salt="kat", indices=[2,10] — the KAT from kiosk-pow-equihash) so
# the test is fast and reproducible. The shipped Python solver produces the same
# {indices, header_nonce} shape for production (n=192, k=7); solver↔verifier
# parity is the gem's concern. This spec proves the GATE ORCHESTRATION with the
# real equihash crypto: N distinct challenges, verify-through-backend, the
# all-or-re-challenge quota, spend semantics, and fingerprint binding.
RSpec.describe "PowGate × equihash (real backend, real gate)" do
  # The kiosk-pow-equihash known-answer proof.
  KAT_SALT   = "kat"
  KAT_PARAMS = { n: 8, k: 1 }.freeze
  KAT_NONCE  = { indices: [2, 10] }.freeze

  before(:each) do
    Kiosk::Reputation::Backends.register("equihash", Kiosk::Pow::Equihash)
    Kiosk.configure do |c|
      c.reputation_policy = equihash_policy
      c.pow_secret        = secret
      c.schema            = "kiosk"
    end
  end

  after(:each) do
    Kiosk::Reputation::Backends.reset!
    Kiosk.reset!
  end

  let(:identity) { build_identity }
  let(:secret)   { "equihash-e2e-secret" }
  let(:count)    { 1 }

  # Policy that demands `count` equihash proofs at the KAT params.
  let(:equihash_policy) do
    demanded = count
    params   = KAT_PARAMS
    Class.new(Kiosk::Reputation::Policy) do
      define_method(:challenge_for) do |identity:, verb:, factors:|
        { alg: "equihash", params: params, count: demanded }
      end
    end.new
  end

  # Hand-mint a signed challenge bound to (command, body) with salt=KAT so the
  # KAT nonce verifies through the real backend. This is exactly what the gate
  # itself emits (same Challenge.issue), but with a controlled salt + id.
  def kat_challenge(id:, command: "query", body: { name: "menu" })
    fp = Kiosk::Server::PowGate.request_fingerprint(command: command, body: body)
    Kiosk::Reputation::Challenge.issue(
      alg:                 "equihash",
      params:              KAT_PARAMS,
      request_fingerprint: fp,
      secret:              secret,
      ttl:                 300,
      salt:                KAT_SALT.b,
      id:                  id,
    )
  end

  it "issues `count` equihash challenges on an unproven request (the 402 shape)" do
    err = nil
    begin
      Kiosk::Server::PowGate.gate(identity: identity, command: "query", body: { name: "menu" }, pow: nil)
    rescue Kiosk::Server::Errors::PowRequired => e
      err = e
    end

    expect(err).not_to be_nil
    expect(err.challenges.length).to eq(count)
    expect(err.challenges.first[:alg]).to eq("equihash")
    expect(err.challenges.first[:params]).to eq(KAT_PARAMS)
  end

  it "proceeds when the real equihash verifier accepts the submitted proof (N=1)" do
    proof = { challenge: kat_challenge(id: "c1"), nonce: KAT_NONCE }

    result = Kiosk::Server::PowGate.gate(
      identity: identity, command: "query", body: { name: "menu" },
      pow: { proofs: [proof] },
    )
    expect(result).to eq(:proceed)
  end

  it "rejects a WRONG nonce through the real verifier (403 + penalty)" do
    penalty = []
    Kiosk.configure { |c| c.on_bad_proof = ->(identity:) { penalty << identity } }

    proof = { challenge: kat_challenge(id: "c1"), nonce: { indices: [3, 10] } } # not a valid solution

    expect {
      Kiosk::Server::PowGate.gate(
        identity: identity, command: "query", body: { name: "menu" },
        pow: { proofs: [proof] },
      )
    }.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)
    expect(penalty).to eq([identity])
  end

  context "N = 3 independent proofs" do
    let(:count) { 3 }

    it "proceeds only when ALL three verify; a short set re-challenges" do
      proofs = %w[c1 c2 c3].map { |id| { challenge: kat_challenge(id: id), nonce: KAT_NONCE } }

      expect {
        Kiosk::Server::PowGate.gate(
          identity: identity, command: "query", body: { name: "menu" },
          pow: { proofs: proofs.first(2) },
        )
      }.to raise_error(Kiosk::Server::Errors::PowRequired)

      result = Kiosk::Server::PowGate.gate(
        identity: identity, command: "query", body: { name: "menu" },
        pow: { proofs: proofs },
      )
      expect(result).to eq(:proceed)
    end
  end

  it "rejects a valid proof submitted against a DIFFERENT request (fingerprint binding)" do
    # Challenge minted for body {name: menu}; submitted against {name: items}.
    proof = { challenge: kat_challenge(id: "c1", body: { name: "menu" }), nonce: KAT_NONCE }

    expect {
      Kiosk::Server::PowGate.gate(
        identity: identity, command: "query", body: { name: "items" },
        pow: { proofs: [proof] },
      )
    }.to raise_error(Kiosk::Server::Errors::PowRequired)
  end
end
