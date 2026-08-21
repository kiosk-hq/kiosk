# frozen_string_literal: true

# WireController 402 WWW-Authenticate header specs.
#
# De-overloading the two 402 gates: the `WWW-Authenticate` response header
# NAMES the gate (Kiosk-PoW vs Payment) so a client can disambiguate at the
# header level, while the JSON body STILL carries the structured payload (the
# PoW N-challenge list / the payment_setup pointer). Both 402s render through
# WireController#render_wire_error — since the 0.4 cutover that is an RFC 9457
# problem document served as `application/problem+json`, so the code a client
# branches on is the TOP-LEVEL `code` member and the hint/challenges payload
# rides alongside it as extension members. Neither half of the de-overloading
# moved: the header still names the gate, the body still carries the payload.
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

    # THE RESERVED PLANE pays the same toll and answers the same way. `pay` is
    # not a per-verb endpoint — it is one of the two the engine draws itself —
    # and through 0.3 it answered the envelope while the per-verb wire answered
    # a problem document. The cutover deleted that split: there is one answer
    # shape on every Kiosk endpoint now, and this is `POST <endpoint>/pay`
    # proving it for the PoW gate.
    it "carries WWW-Authenticate: Kiosk-PoW AND the challenges, on the reserved POST pay" do
      status, headers, problem = dispatch(
        :pay,
        bearer_env("/kiosk/pay", agent_token, method: "POST",
                   input: JSON.generate(
                     intent_mandate_jws: "x", cart_mandate_jws: "y", payment_mandate_jws: "z",
                   ),
                   "CONTENT_TYPE" => "application/json"),
      )
      expect(status).to eq(402)
      expect(headers["WWW-Authenticate"]).to eq('Kiosk-PoW realm="https://demo.example"')
      expect(headers["Content-Type"]).to include("application/problem+json")
      # Body payload preserved (header names, body carries).
      expect(problem[:code]).to   eq("pow_required")
      expect(problem[:type]).to   eq("https://kiosk.tech/problems/pow_required")
      expect(problem[:status]).to eq(402)
      expect(problem[:challenges]).to be_an(Array)
      expect(problem[:challenges]).not_to be_empty
      # The retired envelope leaves no residue at either nesting.
      expect(problem).not_to have_key(:ok)
      expect(problem).not_to have_key(:error)
    end

    # THE SAME GATE ON THE 0.4 PER-VERB WIRE (T-068 slice 2). Everything that
    # de-overloads the three 402s survives the move to RFC 9457: the header
    # still names the gate, the challenges still ride in the body, and the
    # code an assistant branches on is still `pow_required` — now a top-level
    # `code` member rather than `error.code`, and also the `type` URI.
    it "answers a per-verb GET the same gate as a problem document, uncacheable" do
      declare_query("menu") { render json: [] }
      env = bearer_env("/kiosk/menu", agent_token)
      env["action_dispatch.request.path_parameters"] =
        { controller: "kiosk/server/verb", action: "show", kiosk_verb: "menu" }
      status, headers, body = Kiosk::Server::VerbController.action(:show).call(env)
                                                           .then { |s, h, b|
                                                             raw = +""
                                                             b.each { |c| raw << c }
                                                             [s, h, JSON.parse(raw, symbolize_names: true)]
                                                           }

      expect(status).to eq(402)
      expect(headers["WWW-Authenticate"]).to eq('Kiosk-PoW realm="https://demo.example"')
      expect(headers["Content-Type"]).to include("application/problem+json")
      # Rule 2 of design §3.3: a single-use challenge is never cacheable, and
      # `no-store` is the one directive an operator cannot relax.
      expect(headers["Cache-Control"]).to eq("no-store")
      expect(headers["Vary"]).to eq("Authorization, Kiosk-PoW")
      expect(body[:code]).to   eq("pow_required")
      expect(body[:type]).to   eq("https://kiosk.tech/problems/pow_required")
      expect(body[:status]).to eq(402)
      expect(body[:challenges]).to be_an(Array)
      expect(body[:challenges]).not_to be_empty
    end

    # §3.7.5 (matrix SPEC-017), a MUST: the toll gate runs BEFORE the
    # freshness check, because a `304` is a SERVED response. An origin that
    # answered `304 Not Modified` to an untolled conditional request would
    # hand out an unlimited, un-metered "yes, your copy is current" oracle —
    # exactly the answer the toll exists to charge for — and an assistant that
    # cached one paid answer could then poll it free forever.
    #
    # THE CONTROL IS THE SECOND HALF, and it is what makes this more than "the
    # conditional headers are ignored everywhere": the SAME `If-None-Match: *`
    # against `GET <endpoint>/schema`, which is untolled by design, DOES get a
    # `304`. So the conditional request is understood by this tree; the tolled
    # plane refuses it on purpose rather than by not implementing it.
    it "answers 402 to a CONDITIONAL request — the toll runs before freshness" do
      declare_query("menu") { render json: [] }
      env = bearer_env("/kiosk/menu", agent_token,
                       "HTTP_IF_NONE_MATCH"     => "*",
                       "HTTP_IF_MODIFIED_SINCE" => "Sun, 06 Nov 2044 08:49:37 GMT")
      env["action_dispatch.request.path_parameters"] =
        { controller: "kiosk/server/verb", action: "show", kiosk_verb: "menu" }
      status, _headers, body = Kiosk::Server::VerbController.action(:show).call(env)
      body.each { |_c| nil }

      expect(status).to eq(402)

      # The control: an untolled endpoint in the same process DOES honour it.
      sch_status, = Kiosk::Server::WireController.action(:schema).call(
        Rack::MockRequest.env_for("/kiosk/schema", "HTTP_IF_NONE_MATCH" => "*"),
      )
      expect(sch_status).to eq(304)
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
      status, headers, problem = dispatch(
        :pay,
        bearer_env("/kiosk/pay", agent_token, method: "POST",
                   input: JSON.generate(
                     intent_mandate_jws:  "x", cart_mandate_jws: "y", payment_mandate_jws: "z",
                   ),
                   "CONTENT_TYPE" => "application/json"),
      )
      expect(status).to eq(402)
      expect(headers["WWW-Authenticate"]).to eq('Payment realm="https://demo.example", method="ap2"')
      expect(headers["Content-Type"]).to include("application/problem+json")
      # Body payload preserved: the payment_setup_required code + hint pointer.
      # The OTHER 402 of the pair — same status, same endpoint, different code —
      # which is exactly why the code member is the branch point.
      expect(problem[:code]).to   eq("payment_setup_required")
      expect(problem[:type]).to   eq("https://kiosk.tech/problems/payment_setup_required")
      expect(problem[:status]).to eq(402)
      expect(problem[:hint]).to include("payment_setup")
      expect(problem).not_to have_key(:challenges)
    end
  end

  # ─── payment_failed → NO WWW-Authenticate ──────────────────────────────
  #
  # K-749(a). §9 carries a MUST NOT — an operator MUST NOT emit a
  # `WWW-Authenticate` header on `payment_failed` — and NOTHING in the tree
  # asserted it, because nothing asserted the ABSENCE of that header on any
  # response at all. The behaviour is right BY CONSTRUCTION:
  # `www_authenticate_for` is a two-`when` `case` with no `else`, so every
  # other code falls through to nil. That construction is one `else` away from
  # violating a MUST with the whole suite still green — a diagnostic default, a
  # rescue that sets a challenge — which is exactly what a by-construction
  # property needs a test for.
  #
  # `payment_failed` is the third 402 and the reason the rule exists: the other
  # two name a gate the client can act on (solve a proof / set up a card), and
  # this one names none — the charge was attempted and did not go through, and
  # there is no scheme to re-present credentials under.
  describe "the payment_failed 402" do
    before do
      # No database: the executor is stubbed to fail the way a PSP decline
      # reaches the render seam, which is the only part this example is about.
      ar_base = Class.new do
        define_singleton_method(:connection)       { Object.new }
        define_singleton_method(:lease_connection) { Object.new }
      end
      stub_const("ActiveRecord::Base", ar_base)
      allow(Kiosk::Server::Executor).to receive(:call).and_raise(
        Kiosk::Server::Errors::PaymentFailed.new(
          "the card was declined", hint: "the human may need to update the payment method",
        ),
      )
    end

    it "carries NO WWW-Authenticate header — no scheme names this gate (§9)" do
      declare_action("checkout")
      env = bearer_env("/kiosk/checkout", agent_token, method: "POST",
                       input: "{}", "CONTENT_TYPE" => "application/json")
      env["action_dispatch.request.path_parameters"] =
        { controller: "kiosk/server/verb", action: "create", kiosk_verb: "checkout" }
      status, headers, raw = Kiosk::Server::VerbController.action(:create).call(env)
      body = +""
      raw.each { |chunk| body << chunk }
      problem = JSON.parse(body, symbolize_names: true)

      expect(status).to eq(402)
      expect(problem[:code]).to eq("payment_failed")
      expect(headers.to_h.transform_keys(&:downcase)).not_to have_key("www-authenticate")
      # The control: the SAME render seam DOES stamp the header for the two
      # codes that have a scheme, which is asserted above — so this absence is
      # a decision, not a seam that never emits anything.
    end
  end

  # ─── non-402 errors carry NO WWW-Authenticate header ───────────────────
  #
  # Dialed at `pay` rather than at `schema`: T-094 made `GET /kiosk/schema`
  # public, so it resolves no identity and can no longer produce a 401 to
  # check the header against. `pay` is the other reserved endpoint and reaches
  # the same `resolve_identity!`.
  it "does not emit WWW-Authenticate on a non-402 error (e.g. 401)" do
    status, headers, = dispatch(:pay, bearer_env("/kiosk/pay", "garbage", method: "POST",
                                                 input: "{}", "CONTENT_TYPE" => "application/json"))
    expect(status).to eq(401)
    expect(headers).not_to have_key("WWW-Authenticate")
  end
end
