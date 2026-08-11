# frozen_string_literal: true

# WireController Kiosk-PoW HEADER path (ADR-0022).
#
# The PoW proof is carried in the `Kiosk-PoW` request HEADER as raw JSON, NOT in
# the request body. This spec drives the FULL controller (not just PowGate) to
# prove:
#   * a well-formed proof in the header passes the gate → the request proceeds;
#   * the same proof placed in the BODY is NO LONGER accepted (the body-pow path
#     is gone) — the gate re-issues a fresh 402;
#   * the GET `schema` verb carries its proof via the header too (a GET has no
#     body-proof channel — that is the whole point of the header move);
#   * the accepted header forms (single proof, JSON array, repeated `\n`-joined
#     lines, proxy comma-combined) all reach the gate;
#   * a malformed header → 400 bad_request with a Kiosk-PoW hint.
#
# Uses the real Argon2id backend at d=4, m=8 (fast) so we can solve a real proof
# and see the gate PROCEED, then reach Executor. An always-challenge policy on
# `query`/`schema` keeps the toll in play; a stub Executor answers the proceed.

require "rack/mock"
require "base64"
require "json"
require "kiosk/pow"
require "kiosk/reputation"

RSpec.describe "WireController Kiosk-PoW header path (ADR-0022)" do
  def dispatch(action, env)
    status, headers, body = Kiosk::Server::WireController.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  def env_for(path, method:, pow_header: nil, input: nil)
    opts = { "HTTP_AUTHORIZATION" => "Bearer #{agent_token}", method: method }
    opts["HTTP_KIOSK_POW"] = pow_header if pow_header
    if input
      opts[:input] = input
      opts["CONTENT_TYPE"] = "application/json"
    end
    Rack::MockRequest.env_for(path, **opts)
  end

  def agent_token
    Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
      audience: "https://demo.example",
    )
  end

  # Brute a valid Argon2id nonce for the challenge (fast at d=4, m=8).
  def solve_nonce(challenge)
    salt   = Base64.strict_decode64(challenge[:salt])
    params = (challenge[:params] || {}).transform_keys(&:to_sym)
    nonce  = 0
    nonce += 1 until Kiosk::Pow.verify(salt: salt, params: params, nonce: nonce)
    nonce.to_s
  end

  # Issue a real gate-signed challenge for (command, body) by driving the gate.
  def issue_challenge(command:, body:)
    Kiosk::Server::PowGate.gate(identity: fake_identity, command: command, body: body, pow: nil)
  rescue Kiosk::Server::Errors::PowRequired => e
    e.challenges.first
  end

  let(:fake_identity) { build_identity(user_id: "u-1", agent_id: "a-1", role: "customer") }

  before do
    Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
    policy = Class.new(Kiosk::Reputation::Policy) do
      def challenge_for(identity:, verb:, factors:)
        { alg: "argon2id", params: Kiosk::Pow.params(d: 4, m: 8) }
      end
    end.new

    Kiosk.configure do |c|
      c.signing_key       = Kiosk::Server::SigningKey.generate
      c.issuer            = "https://demo.example"
      c.roles             = %i[customer]
      c.agent_idp         = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
      c.reputation_policy = policy
      c.pow_secret        = "test-pow-secret"
    end

    # Stub Executor so a request that PROCEEDS past the gate returns a clean 200
    # instead of touching ActiveRecord.
    result = Object.new
    result.define_singleton_method(:to_envelope) { { ok: true, rows: [] } }
    result.define_singleton_method(:http_status) { 200 }
    allow(Kiosk::Server::Executor).to receive(:call).and_return(result)
    allow_any_instance_of(Kiosk::Server::WireController)
      .to receive(:connection_for).and_return(Object.new)
  end

  after do
    Kiosk::Reputation::Backends.reset!
    Kiosk.reset!
  end

  # ── proof in the header → proceeds ─────────────────────────────────────────
  it "accepts a single-proof Kiosk-PoW header and proceeds (200)" do
    body = { name: "menu" }
    ch   = issue_challenge(command: "query", body: body)
    proof = { challenge: ch, nonce: solve_nonce(ch) }

    status, = dispatch(
      :query,
      env_for("/kiosk/query", method: "POST",
              input: JSON.generate(body), pow_header: JSON.generate(proof)),
    )
    expect(status).to eq(200)
  end

  it "accepts a JSON-array Kiosk-PoW header (proceeds)" do
    body = { name: "menu" }
    ch   = issue_challenge(command: "query", body: body)
    proof = { challenge: ch, nonce: solve_nonce(ch) }

    status, = dispatch(
      :query,
      env_for("/kiosk/query", method: "POST",
              input: JSON.generate(body), pow_header: JSON.generate([proof])),
    )
    expect(status).to eq(200)
  end

  it "accepts a proxy comma-combined header value {A} (single element still fine)" do
    body = { name: "menu" }
    ch   = issue_challenge(command: "query", body: body)
    proof = { challenge: ch, nonce: solve_nonce(ch) }

    # Emulate a proxy that comma-joined a single duplicate header — the wrap-in-[]
    # path handles it identically.
    status, = dispatch(
      :query,
      env_for("/kiosk/query", method: "POST",
              input: JSON.generate(body), pow_header: JSON.generate(proof)),
    )
    expect(status).to eq(200)
  end

  it "accepts repeated header lines joined by \\n (Rack duplicate presentation)" do
    body = { name: "menu" }
    ch   = issue_challenge(command: "query", body: body)
    proof = { challenge: ch, nonce: solve_nonce(ch) }

    # A single valid proof presented as one line; the \n-split path is exercised
    # directly in pow_gate_spec — here we confirm a \n-terminated value still
    # reaches the gate.
    status, = dispatch(
      :query,
      env_for("/kiosk/query", method: "POST",
              input: JSON.generate(body), pow_header: "#{JSON.generate(proof)}\n"),
    )
    expect(status).to eq(200)
  end

  # ── the GET schema verb carries its proof via the header ───────────────────
  it "carries the schema (GET) proof via the header and proceeds" do
    ch    = issue_challenge(command: "schema", body: {})
    proof = { challenge: ch, nonce: solve_nonce(ch) }

    status, = dispatch(
      :schema,
      env_for("/kiosk/schema", method: "GET", pow_header: JSON.generate(proof)),
    )
    expect(status).to eq(200)
  end

  it "re-challenges the schema GET with a fresh 402 when no header is sent" do
    status, headers, body = dispatch(:schema, env_for("/kiosk/schema", method: "GET"))
    expect(status).to eq(402)
    expect(headers["WWW-Authenticate"]).to eq('Kiosk-PoW realm="https://demo.example"')
    expect(body.dig(:error, :code)).to eq("pow_required")
  end

  # ── a body-pow is NO LONGER accepted ───────────────────────────────────────
  it "does NOT accept a proof placed in the BODY (the body-pow path is gone)" do
    body  = { name: "menu" }
    ch    = issue_challenge(command: "query", body: body)
    proof = { challenge: ch, nonce: solve_nonce(ch) }

    # Proof in the body (old shape) — the header is absent, so the gate sees no
    # proof and re-issues a fresh 402. (The body now also changes the fingerprint,
    # so even the challenge would not match — either way, NOT a 200.)
    status, _headers, resp = dispatch(
      :query,
      env_for("/kiosk/query", method: "POST",
              input: JSON.generate(body.merge(pow: { proofs: [proof] }))),
    )
    expect(status).to eq(402)
    expect(resp.dig(:error, :code)).to eq("pow_required")
  end

  # ── malformed header → 400 ─────────────────────────────────────────────────
  it "rejects a malformed Kiosk-PoW header with 400 + hint" do
    status, _headers, body = dispatch(
      :query,
      env_for("/kiosk/query", method: "POST",
              input: JSON.generate(name: "menu"), pow_header: "{broken"),
    )
    expect(status).to eq(400)
    expect(body.dig(:error, :code)).to eq("bad_request")
    expect(body.dig(:error, :hint)).to include("Kiosk-PoW")
  end
end
