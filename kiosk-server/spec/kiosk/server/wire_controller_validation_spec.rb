# frozen_string_literal: true

# WireController opt-in request-shape validation (UNIFORM-VALIDATION slice-1,
# closes K-479).
#
# When `config.validate_requests` is true, a PRESENT `pow` field is validated
# against the vendored normative PoW schema BEFORE PowGate.gate consumes it. The
# motivating failure: an agent submitted `pow: {solutions:[…]}` (not the schema
# shape `{proofs:[{challenge:,nonce:}]}`); PowGate.extract_proofs returned [] and
# the gate re-issued a fresh 402 on every retry — an infinite loop with no
# diagnostic. This layer turns that silent re-challenge into a clear 400 hint.
#
# Like wire_controller_402_spec.rb: pull in actionpack and re-`load` the
# controller, then dispatch through ActionController::Metal.action.

require "action_controller"
require "rack/mock"
require "json"
require "kiosk/pow"
require "kiosk/reputation"

load File.expand_path("../../../lib/kiosk/server/wire_controller.rb", __dir__)

RSpec.describe "WireController opt-in request validation (slice-1, K-479)" do
  def dispatch(action, env)
    status, headers, body = Kiosk::Server::WireController.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  def bearer_env(path, token, **opts)
    Rack::MockRequest.env_for(path, "HTTP_AUTHORIZATION" => "Bearer #{token}", **opts)
  end

  def agent_token
    Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
      audience: "https://demo.example",
    )
  end

  # Post a query request whose body carries `pow`. An always-challenge
  # reputation policy is configured (see the shared `before`), so a request
  # that CLEARS validation reaches PowGate.gate and comes back 402 pow_required
  # — never touching Executor / ActiveRecord. That lets us assert cleanly on the
  # validation OUTCOME: a malformed pow is a 400 (rejected before the gate), a
  # valid/absent pow is a 402 (validation passed it through to the gate).
  def post_pow(pow)
    body = { name: "menu" }
    body[:pow] = pow unless pow == :absent
    dispatch(
      :query,
      bearer_env("/kiosk/query", agent_token, method: "POST",
                 input: JSON.generate(body), "CONTENT_TYPE" => "application/json"),
    )
  end

  # A structurally VALID challenge object (all schema-required fields present).
  def valid_challenge
    {
      id:     "chal-1",
      alg:    "equihash",
      params: { n: 168, k: 7 },
      salt:   "c2FsdA==",
      exp:    Time.now.to_i + 300,
      sig:    "deadbeef",
    }
  end

  before do
    # An always-challenge policy so a request that clears validation reaches the
    # gate (402 pow_required) rather than Executor — see post_pow.
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
    Kiosk::Server::RequestValidation.reset!
  end

  after do
    Kiosk::Server::RequestValidation.reset!
    Kiosk::Reputation::Backends.reset!
  end

  # ── Flag ON: malformed pow → 400 bad_request with a shape hint ─────────────
  context "with validate_requests: true" do
    before { Kiosk.configure { |c| c.validate_requests = true } }

    it "rejects the K-479 shape ({solutions:[…]}) with 400 bad_request + hint (NOT a 402)" do
      status, _headers, body = post_pow(solutions: [{ indices: [1, 2, 3], header_nonce: 0 }])

      expect(status).to eq(400)
      expect(body.dig(:error, :code)).to eq("bad_request")
      expect(body.dig(:error, :hint)).to include("pow.proofs[]")
      expect(body.dig(:error, :hint)).to include("challenge")
      # It must NOT have been turned into a fresh pow_required challenge.
      expect(body.dig(:error, :code)).not_to eq("pow_required")
    end

    it "rejects a proof missing the echoed challenge with 400 bad_request" do
      status, _headers, body = post_pow(proofs: [{ nonce: { indices: [1, 2, 3] } }])

      expect(status).to eq(400)
      expect(body.dig(:error, :code)).to eq("bad_request")
      expect(body.dig(:error, :hint)).to include("proofs")
    end

    it "does NOT reject a well-formed pow at the validation step (it passes to the gate)" do
      # A well-formed-but-forged proof clears the SHAPE check and reaches the
      # gate, which does the real cryptographic verification — the forged proof
      # fails there and the gate re-issues a fresh 402. The point: validation
      # did NOT reject it with a 400; the gate (not the shape check) is still the
      # authority on whether a proof is valid.
      status, _headers, body = post_pow(
        proofs: [{ challenge: valid_challenge, nonce: { indices: [1, 2, 3, 4] } }],
      )

      expect(status).to eq(402)
      expect(body.dig(:error, :code)).to eq("pow_required")
      expect(body.dig(:error, :code)).not_to eq("bad_request")
    end

    it "accepts the single-proof shorthand (no proofs wrapper)" do
      status, _headers, body = post_pow(
        challenge: valid_challenge, nonce: { indices: [1, 2, 3, 4] },
      )

      expect(status).to eq(402)
      expect(body.dig(:error, :code)).not_to eq("bad_request")
    end

    it "leaves an ABSENT pow untouched — the normal 402 challenge path runs (no 400)" do
      # An absent pow means the initial request; the gate must still issue the
      # normal pow_required 402. Missing pow is NOT a malformed pow — it must
      # never become a 400.
      status, _headers, body = post_pow(:absent)

      expect(status).to eq(402)
      expect(body.dig(:error, :code)).to eq("pow_required")
      expect(body.dig(:error, :code)).not_to eq("bad_request")
    end
  end

  # ── Flag OFF (default): a malformed pow behaves exactly as today ───────────
  context "with validate_requests off (default)" do
    it "does NOT raise a validation error on a malformed pow (byte-identical to today)" do
      # With the flag off, the malformed pow is simply ignored by
      # extract_proofs ([] proofs) and the gate re-issues a fresh 402 — the exact
      # K-479 pre-fix behaviour. The point: no 400 bad_request from a validation
      # step that isn't running.
      status, _headers, body = post_pow(solutions: [{ indices: [1, 2, 3] }])

      expect(status).to eq(402)
      expect(body.dig(:error, :code)).to eq("pow_required")
      expect(body.dig(:error, :code)).not_to eq("bad_request")
    end
  end

  # ── Fail-loud when the optional gem is missing ─────────────────────────────
  context "when validate_requests is on but json_schemer is not loadable" do
    before do
      Kiosk.configure { |c| c.validate_requests = true }
      Kiosk::Server::RequestValidation.reset!
      allow(Kiosk::Server::RequestValidation).to receive(:require)
        .with("json_schemer").and_raise(LoadError)
    end

    it "raises a ConfigurationError naming the gem" do
      expect {
        Kiosk::Server::RequestValidation.validate_pow!(proofs: [])
      }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /json_schemer/)
    end
  end
end
