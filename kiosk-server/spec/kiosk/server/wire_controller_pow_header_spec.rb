# frozen_string_literal: true

# The Kiosk-PoW HEADER path (ADR-0022), driven through the FULL controllers.
#
# The proof is carried in the `Kiosk-PoW` request HEADER as raw JSON, never in
# the request body. On the 0.4 per-verb wire that is not a convenience but the
# only workable channel: a query is a `GET <endpoint>/<query-name>` and a GET
# has no body to put a proof in. This spec proves, end to end:
#
#   * a well-formed proof in the header passes the gate → the call proceeds;
#   * the controller feeds the gate the METHOD and the PATH-SEGMENT verb, so a
#     proof solved for `GET /kiosk/catalog?q=milk` is spendable there and on no
#     other endpoint;
#   * the reserved `GET <endpoint>/schema` is NEVER tolled — it went public in
#     T-094, and a toll needs an identity to charge;
#   * every accepted header form (single proof, JSON array, repeated
#     `\n`-joined lines, proxy comma-combined) reaches the gate;
#   * a proof placed in an action's BODY is not a proof — the gate re-challenges;
#   * a malformed header → 400 bad_request problem document with a Kiosk-PoW hint.
#
# Uses the real Argon2id backend at d=4, m=8 (fast) so a real proof can be
# solved and the gate seen to PROCEED, then reach Executor. An always-challenge
# policy keeps the toll in play on every verb; a stubbed Executor answers the
# proceed without touching ActiveRecord.

require "rack/mock"
require "base64"
require "json"
require "kiosk/pow"
require "kiosk/reputation"

RSpec.describe "Kiosk-PoW header path (ADR-0022)" do
  # ── dispatch ───────────────────────────────────────────────────────────────
  # A per-verb call is `VerbController#show` / `#create` with the verb name in
  # `params[:kiosk_verb]`; `schema` is still a reserved WireController action.

  def dispatch_verb(action, name, env)
    env["action_dispatch.request.path_parameters"] =
      { controller: "kiosk/server/verb", action: action.to_s, kiosk_verb: name.to_s }
    finish(Kiosk::Server::VerbController.action(action).call(env))
  end

  def dispatch_reserved(action, env)
    finish(Kiosk::Server::WireController.action(action).call(env))
  end

  def finish(rack_triplet)
    status, headers, body = rack_triplet
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

  # `GET /kiosk/<name>?<args>` — a query.
  def get_verb(name, query: nil, pow_header: nil)
    path = query.nil? ? "/kiosk/#{name}" : "/kiosk/#{name}?#{query}"
    dispatch_verb(:show, name, env_for(path, method: "GET", pow_header: pow_header))
  end

  # `POST /kiosk/<name>` — an action.
  def post_verb(name, body, pow_header: nil)
    dispatch_verb(
      :create, name,
      env_for("/kiosk/#{name}", method: "POST",
              input: JSON.generate(body), pow_header: pow_header),
    )
  end

  def agent_token
    @agent_token ||= Kiosk::Server::JwtIssuer.issue(
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

  # A real gate-signed challenge for the exact call the controller will
  # fingerprint — §3.4's `"<METHOD> <verb>\n<canonical args>"`.
  def issue_challenge(command:, method:, verb:, body: {})
    Kiosk::Server::PowGate.gate(identity: fake_identity, command: command,
                                method: method, verb: verb, body: body, pow: nil)
  rescue Kiosk::Server::Errors::PowRequired => e
    e.challenges.first
  end

  # A solved proof for `GET /kiosk/catalog?q=milk`, the call most examples make.
  def catalog_proof
    ch = issue_challenge(command: "query", method: "GET", verb: "catalog", body: { q: "milk" })
    { challenge: ch, nonce: solve_nonce(ch) }
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

    # The verbs this spec dials. Two queries, so a proof for one can be shown
    # NOT to work on the other; one action, for the body-is-not-the-channel case.
    declare_query("catalog")      { render json: [] }
    declare_query("availability") { render json: [] }
    declare_action("place_order") { render json: {} }

    # Stub Executor so a request that PROCEEDS past the gate returns a clean 200
    # instead of touching ActiveRecord.
    allow(Kiosk::Server::Executor).to receive(:call)
      .and_return(Kiosk::Server::Result.new(kind: :rows, payload: []))
    allow_any_instance_of(Kiosk::Server::WireController)
      .to receive(:connection_for).and_return(Object.new)
  end

  after do
    Kiosk::Reputation::Backends.reset!
    Kiosk.reset!
  end

  # ── proof in the header → proceeds ─────────────────────────────────────────
  it "accepts a single-proof Kiosk-PoW header on a per-verb GET and proceeds (200)" do
    status, = get_verb("catalog", query: "q=milk", pow_header: JSON.generate(catalog_proof))

    expect(status).to eq(200)
  end

  it "accepts a JSON-array Kiosk-PoW header (proceeds)" do
    status, = get_verb("catalog", query: "q=milk", pow_header: JSON.generate([catalog_proof]))

    expect(status).to eq(200)
  end

  it "accepts a proxy comma-combined header value {A},{B} (RFC 7230)" do
    # Two independently issued proofs for the SAME call, joined the way a proxy
    # collapses duplicate header lines. Both must reach the gate.
    combined = "#{JSON.generate(catalog_proof)},#{JSON.generate(catalog_proof)}"

    status, = get_verb("catalog", query: "q=milk", pow_header: combined)

    expect(status).to eq(200)
  end

  it "accepts repeated header lines joined by \\n (Rack duplicate presentation)" do
    lines = "#{JSON.generate(catalog_proof)}\n#{JSON.generate(catalog_proof)}"

    status, = get_verb("catalog", query: "q=milk", pow_header: lines)

    expect(status).to eq(200)
  end

  # ── the controller feeds METHOD and PATH SEGMENT to the fingerprint ────────
  #
  # These are the controller-level half of the §3.4 binding proved against the
  # gate in pow_gate_spec: the wire name the endpoint tolls under is the PATH
  # SEGMENT it was reached by, and the method is the request's own.

  it "does NOT accept a catalog proof on another query's endpoint" do
    status, _headers, problem =
      get_verb("availability", query: "q=milk", pow_header: JSON.generate(catalog_proof))

    expect(status).to eq(402)
    expect(problem[:code]).to eq("pow_required")
  end

  it "does NOT accept a GET proof on the POST endpoint of the same name" do
    ch    = issue_challenge(command: "query", method: "GET", verb: "place_order", body: {})
    proof = { challenge: ch, nonce: solve_nonce(ch) }

    status, _headers, problem = post_verb("place_order", {}, pow_header: JSON.generate(proof))

    expect(status).to eq(402)
    expect(problem[:code]).to eq("pow_required")
  end

  it "accepts the matching POST proof on that same action (the control)" do
    ch    = issue_challenge(command: "run", method: "POST", verb: "place_order", body: {})
    proof = { challenge: ch, nonce: solve_nonce(ch) }

    status, = post_verb("place_order", {}, pow_header: JSON.generate(proof))

    expect(status).to eq(200)
  end

  # ── the reserved GET schema is PUBLIC AND FREE (T-094) ─────────────────────
  #
  # This pair asserted the OPPOSITE until 2026-08-19: `schema` was tolled as
  # `:schema`, so one example proved a proof travelled in the header on a GET
  # and the other proved a bare request was re-challenged. Both statements are
  # now false OF `schema` — and NEITHER PROPERTY IS LOST, which is why they are
  # replaced rather than deleted: the header-on-a-GET half is asserted at the
  # top of this file on a per-verb query, and the re-challenge SHAPE is
  # asserted immediately below on one. What goes in their place is the fact
  # that made them false.
  #
  # The toll was the gate's one substantive warrant — enumerating the
  # catalogue should cost something — and it died with the gate: the document
  # is a cacheable static answer, so serving it costs the origin nothing, and
  # a toll has no identity to charge. The policy in this file challenges EVERY
  # verb, which is what makes the 200 below mean something.
  it "never tolls GET /kiosk/schema, under a policy that challenges everything" do
    status, headers, body =
      dispatch_reserved(:schema, Rack::MockRequest.env_for("/kiosk/schema"))

    expect(status).to eq(200)
    expect(headers).not_to have_key("WWW-Authenticate")
    expect(body).to have_key(:queries)
  end

  it "re-challenges a per-verb GET with a fresh 402 problem document when no header is sent" do
    status, headers, problem = get_verb("catalog", query: "q=milk")

    expect(status).to eq(402)
    expect(headers["WWW-Authenticate"]).to eq('Kiosk-PoW realm="https://demo.example"')
    expect(headers["Content-Type"]).to include("application/problem+json")
    expect(problem[:code]).to   eq("pow_required")
    expect(problem[:type]).to   eq("https://kiosk.tech/problems/pow_required")
    expect(problem[:status]).to eq(402)
    expect(problem[:challenges]).to be_an(Array)
    expect(problem[:challenges]).not_to be_empty
  end

  # ── a body-pow is NOT a proof ──────────────────────────────────────────────
  it "does NOT accept a proof placed in an action's BODY (the header is the channel)" do
    ch    = issue_challenge(command: "run", method: "POST", verb: "place_order", body: {})
    proof = { challenge: ch, nonce: solve_nonce(ch) }

    # Old shape: the proof travels in the body and no header is sent. The gate
    # sees no proof and re-issues. (The body is also part of the fingerprint
    # now, so the challenge could not have matched either — both roads lead
    # away from a 200, which is the point.)
    status, _headers, problem = post_verb("place_order", { pow: { proofs: [proof] } })

    expect(status).to eq(402)
    expect(problem[:code]).to eq("pow_required")
  end

  # ── malformed header → 400 problem document ────────────────────────────────
  it "rejects a malformed Kiosk-PoW header with a 400 problem document + hint" do
    status, headers, problem = get_verb("catalog", pow_header: "{broken")

    expect(status).to eq(400)
    expect(headers["Content-Type"]).to include("application/problem+json")
    expect(problem[:code]).to   eq("bad_request")
    expect(problem[:type]).to   eq("https://kiosk.tech/problems/bad_request")
    expect(problem[:status]).to eq(400)
    expect(problem[:hint]).to include("Kiosk-PoW")
  end
end
