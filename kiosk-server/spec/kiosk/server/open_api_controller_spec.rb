# frozen_string_literal: true

# `GET <endpoint>/openapi.json` at the wire level (T-068 slice 4).
#
# The document itself is proved next door in `open_api_spec.rb`. What is
# proved here is that the ENDPOINT behaves like the wire it describes:
# Bearer-gated before it says anything, tolled as `schema` because it renders
# the same catalog, refusing in the 0.4 problem shape, and carrying the cache
# policy every wire response carries.

require "json"
require "rack/mock"
require "kiosk/pow"
require "kiosk/reputation"

RSpec.describe Kiosk::Server::OpenApiController do
  before do
    Kiosk.configure do |c|
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.issuer      = "https://demo.example"
      c.roles       = %i[customer]
      c.agent_idp   = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
    end
    declare_query("salons") { render json: [] }
  end

  def token
    Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
      audience: "https://demo.example",
    )
  end

  def get_document(auth: true, headers: {})
    opts = headers.dup
    opts["HTTP_AUTHORIZATION"] = "Bearer #{token}" if auth
    env = Rack::MockRequest.env_for("/kiosk/openapi.json", method: "GET", **opts)
    env["action_dispatch.request.path_parameters"] =
      { controller: "kiosk/server/open_api", action: "show" }

    status, response_headers, body = described_class.action(:show).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true), response_headers]
  end

  it "answers the derived document to an authenticated caller" do
    status, body, = get_document

    expect(status).to eq(200)
    expect(body[:openapi]).to eq(Kiosk::Server::OpenApi::OPENAPI_VERSION)
    # `/schema` rides along since the cutover — it answers the same 0.4 shapes
    # every other endpoint does, so the derived description covers it too.
    # `/pay` does not: this origin has no payment provider.
    expect(body[:paths].keys).to eq([:"/schema", :"/salons"])
  end

  it "serves it under the OAI-registered media type" do
    _status, _body, headers = get_document

    expect(headers["Content-Type"]).to include("application/vnd.oai.openapi+json")
  end

  it "refuses an UNAUTHENTICATED caller before it will name a single verb" do
    # The document publishes the whole catalog. Serving it publicly would
    # hand an anonymous caller exactly the enumeration the per-verb wire
    # orders its gates (401 before 404) to withhold, and `GET
    # <endpoint>/schema` — the canonical spelling of the same information —
    # is Bearer-gated too.
    status, body, headers = get_document(auth: false)

    expect(status).to eq(401)
    expect(body[:code]).to eq("unauthenticated")
    expect(headers["Content-Type"]).to include(Kiosk::Server::Errors::PROBLEM_CONTENT_TYPE)
  end

  it "refuses in the 0.4 problem shape, not the 0.3 envelope" do
    _status, body, = get_document(auth: false)

    expect(body).to include(:type, :title, :status, :code)
    expect(body).not_to have_key(:ok)
    expect(body).not_to have_key(:error)
  end

  it "carries the cache policy every wire response carries" do
    _status, _body, headers = get_document

    expect(headers["Vary"]).to eq("Authorization, Kiosk-PoW")
    expect(headers["Cache-Control"]).to eq("private, no-store")
  end

  it "pays the SAME toll `schema` pays, so a priced catalog cannot be read around" do
    # The shipped RateAndReputation policy ignores `verb:` and prices every
    # wire call, `schema` included. An untolled description of the same
    # catalog would be a free path around that price.
    Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
    seen   = []
    policy = Class.new(Kiosk::Reputation::Policy) do
      define_method(:challenge_for) do |identity:, verb:, factors:|
        seen << verb
        { alg: "argon2id", params: Kiosk::Pow.params(d: 4, m: 8) }
      end
    end.new
    Kiosk.configure do |c|
      c.reputation_policy = policy
      c.pow_secret        = "test-pow-secret"
    end

    status, body, = get_document

    expect(status).to eq(402)
    expect(body[:code]).to eq("pow_required")
    expect(seen).to eq([:schema])
  end
end
