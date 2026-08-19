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

  # The call under test, as a router reaches it on the 0.4 wire:
  # `GET <endpoint>/catalog?q=milk`. `command:` is the gate/POLICY verb the
  # policy branches on; `method:`/`verb:` are the two halves §3.4's fingerprint
  # binds to alongside the arguments.
  ARGS = { q: "milk" }.freeze

  # Drive the gate for that call. `command:` stays the POLICY verb; any of the
  # three fingerprint inputs can be overridden to build a MISMATCHED submission.
  def gate(pow:, command: "query", method: "GET", verb: "catalog", body: ARGS)
    Kiosk::Server::PowGate.gate(
      identity: identity, command: command, method: method, verb: verb, body: body, pow: pow,
    )
  end

  # Hand-mint a signed challenge bound to (method, verb, args) with salt=KAT so
  # the KAT nonce verifies through the real backend. This is exactly what the
  # gate itself emits (same Challenge.issue), but with a controlled salt + id.
  def kat_challenge(id:, method: "GET", verb: "catalog", body: ARGS)
    fp = Kiosk::Server::PowGate.request_fingerprint(method: method, verb: verb, body: body)
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
      gate(pow: nil)
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

    expect(gate(pow: { proofs: [proof] })).to eq(:proceed)
  end

  it "rejects a WRONG nonce through the real verifier (403 + penalty)" do
    penalty = []
    Kiosk.configure { |c| c.on_bad_proof = ->(identity:) { penalty << identity } }

    proof = { challenge: kat_challenge(id: "c1"), nonce: { indices: [3, 10] } } # not a valid solution

    expect {
      gate(pow: { proofs: [proof] })
    }.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)
    expect(penalty).to eq([identity])
  end

  context "N = 3 independent proofs" do
    let(:count) { 3 }

    it "proceeds only when ALL three verify; a short set re-challenges" do
      proofs = %w[c1 c2 c3].map { |id| { challenge: kat_challenge(id: id), nonce: KAT_NONCE } }

      expect {
        gate(pow: { proofs: proofs.first(2) })
      }.to raise_error(Kiosk::Server::Errors::PowRequired)

      expect(gate(pow: { proofs: proofs })).to eq(:proceed)
    end
  end

  # ── fingerprint binding, through the real crypto ─────────────────────────
  #
  # §3.4 hashes "<METHOD> <verb>\n<canonical args>", so a proof solved for
  # `GET catalog?q=milk` is spendable on that call and on nothing else. Each
  # example below mints its challenge for THAT call and submits it against a
  # request differing in exactly ONE of the three inputs; the N=1 example above
  # is the matching control that shows the proof itself is good.
  describe "a valid proof submitted against a DIFFERENT request" do
    it "re-challenges when the ARGUMENTS differ" do
      proof = { challenge: kat_challenge(id: "c1"), nonce: KAT_NONCE }

      expect {
        gate(pow: { proofs: [proof] }, body: { q: "bread" })
      }.to raise_error(Kiosk::Server::Errors::PowRequired)
    end

    it "re-challenges when the METHOD differs (a GET catalog proof on POST catalog)" do
      proof = { challenge: kat_challenge(id: "c1"), nonce: KAT_NONCE }

      expect {
        gate(pow: { proofs: [proof] }, command: "run", method: "POST")
      }.to raise_error(Kiosk::Server::Errors::PowRequired)
    end

    it "re-challenges when the VERB differs (a catalog proof is not an orders proof)" do
      proof = { challenge: kat_challenge(id: "c1"), nonce: KAT_NONCE }

      expect {
        gate(pow: { proofs: [proof] }, verb: "orders")
      }.to raise_error(Kiosk::Server::Errors::PowRequired)
    end
  end
end
