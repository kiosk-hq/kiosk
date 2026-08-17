# frozen_string_literal: true

# WireController 402 WWW-Authenticate header specs.
#
# De-overloading the two 402 gates: the `WWW-Authenticate` response header
# NAMES the gate (Kiosk-PoW vs Payment) so a client can disambiguate at the
# header level, while the JSON body STILL carries the structured payload (the
# PoW N-challenge list / the payment_setup pointer). Both 402s render through
# WireController#render_envelope.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host.

require "rack/mock"
require "json"
require "kiosk/pow"
require "kiosk/reputation"

RSpec.describe "WireController 402 WWW-Authenticate (W4)" do
  def dispatch(action, env)
    status, headers, body = Kiosk::Server::WireController.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  def bearer_env(path, token, **opts)
    Rack::MockRequest.env_for(path, "HTTP_AUTHORIZATION" => "Bearer #{token}", **opts)
  end

  before do
    Kiosk.configure do |c|
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.issuer      = "https://demo.example"
      c.roles       = %i[customer]
      c.agent_idp   = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
    end
  end

  def agent_token
    Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
      audience: "https://demo.example",
    )
  end

  # ─── PoW gate → WWW-Authenticate: Kiosk-PoW ────────────────────────────
  describe "the pow_required 402" do
    before do
      Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
      policy = Class.new(Kiosk::Reputation::Policy) do
        def challenge_for(identity:, verb:, factors:)
          { alg: "argon2id", params: Kiosk::Pow.params(d: 4, m: 8) }
        end
      end.new
      Kiosk.configure do |c|
        c.reputation_policy = policy
        c.pow_secret        = "test-pow-secret"
      end
    end

    after { Kiosk::Reputation::Backends.reset! }

    it "carries WWW-Authenticate: Kiosk-PoW AND the challenges body" do
      status, headers, body = dispatch(
        :query,
        bearer_env("/kiosk/query", agent_token, method: "POST",
                   input: JSON.generate(name: "menu"), "CONTENT_TYPE" => "application/json"),
      )
      expect(status).to eq(402)
      expect(headers["WWW-Authenticate"]).to eq('Kiosk-PoW realm="https://demo.example"')
      # Body payload preserved (header names, body carries).
      expect(body.dig(:error, :code)).to eq("pow_required")
      expect(body.dig(:error, :challenges)).to be_an(Array)
      expect(body.dig(:error, :challenges)).not_to be_empty
    end
  end

  # ─── Payment-setup gate → WWW-Authenticate: Payment ────────────────────
  describe "the payment_setup_required 402" do
    before do
      # A provider that knows the principal has no card on file → the pay verb
      # raises PaymentSetupRequired BEFORE opening any DB transaction.
      provider = Object.new
      provider.define_singleton_method(:setup_required?) { |user_id:| true }
      Kiosk.configure { |c| c.payment_provider = provider }

      # connection_for(identity) touches ActiveRecord::Base.connection; the pay
      # verb only USES it after the setup check, so a bare stub suffices.
      ar_base = Class.new do
        define_singleton_method(:connection)       { Object.new }
        define_singleton_method(:lease_connection) { Object.new }
      end
      stub_const("ActiveRecord::Base", ar_base)
    end

    it "carries WWW-Authenticate: Payment ... method=\"ap2\" AND the body pointer" do
      status, headers, body = dispatch(
        :pay,
        bearer_env("/kiosk/pay", agent_token, method: "POST",
                   input: JSON.generate(
                     intent_mandate_jws:  "x", cart_mandate_jws: "y", payment_mandate_jws: "z",
                   ),
                   "CONTENT_TYPE" => "application/json"),
      )
      expect(status).to eq(402)
      expect(headers["WWW-Authenticate"]).to eq('Payment realm="https://demo.example", method="ap2"')
      # Body payload preserved: the payment_setup_required code + hint pointer.
      expect(body.dig(:error, :code)).to eq("payment_setup_required")
      expect(body.dig(:error, :hint)).to include("payment_setup")
    end
  end

  # ─── non-402 errors carry NO WWW-Authenticate header ───────────────────
  it "does not emit WWW-Authenticate on a non-402 error (e.g. 401)" do
    status, headers, = dispatch(:schema, bearer_env("/kiosk/schema", "garbage"))
    expect(status).to eq(401)
    expect(headers).not_to have_key("WWW-Authenticate")
  end
end
