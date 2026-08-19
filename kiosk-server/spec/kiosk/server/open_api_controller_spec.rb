# frozen_string_literal: true

# `GET <endpoint>/openapi.json` at the wire level (T-068 slice 4, K-804).
#
# The document itself is proved next door in `open_api_spec.rb`. What is
# proved here is that the ENDPOINT behaves like the OTHER public description
# of the same registry: no credential, no toll, a public cache policy with a
# strong ETag and a 304, a year at the versioned url — and NO `Vary`, which is
# the half a `Rack::MockRequest` cannot see unless it is made to negotiate.

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

  def get_document(auth: false, path: "/kiosk/openapi.json", headers: {})
    opts = headers.dup
    opts["HTTP_AUTHORIZATION"] = "Bearer #{token}" if auth
    env = Rack::MockRequest.env_for(path, method: "GET", **opts)
    env["action_dispatch.request.path_parameters"] =
      { controller: "kiosk/server/open_api", action: "show" }

    status, response_headers, body = described_class.action(:show).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true), response_headers]
  end

  # ─── public (K-804) ──────────────────────────────────────────────────────
  #
  # Until 2026-08-19 the first four examples in this file asserted the
  # opposite: 401 to an anonymous caller, a `:schema` toll, and the wire's
  # `private, no-store` + `Vary: Authorization, Kiosk-PoW`. The reason given
  # for the gate — that an anonymous read hands out the catalog enumeration —
  # had been retired for `GET <endpoint>/schema` (T-094) and for
  # `/.well-known/api-catalog` (T-093) on the same day. Phil: «K-804
  # открывать».
  it "answers the derived document to a caller with NO credential" do
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

  it "does not read a Bearer token even when one is sent" do
    with, = get_document(auth: true)
    without, = get_document

    expect([with, without]).to eq([200, 200])
  end

  it "is NOT tolled — a toll needs an identity, and there is none here" do
    # The shipped RateAndReputation policy ignores `verb:` and prices every
    # wire call it is asked about. This endpoint no longer asks: the gate that
    # would have charged `:schema` is gone with the identity it charged.
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

    status, = get_document

    expect(status).to eq(200)
    expect(seen).to be_empty
  end

  # ─── the cache policy, which came in the gate's place ────────────────────
  it "carries the PUBLIC cache policy and a strong ETag" do
    _status, _body, headers = get_document

    expect(headers["Cache-Control"]).to eq("max-age=60, public")
    expect(headers["ETag"]).to match(/\A"[0-9a-f]{32}"\z/)
  end

  # A REAL CLIENT SENDS AN ACCEPT HEADER, AND RAILS REACTS TO IT.
  # `ActionController::Rendering#_set_vary_header` stamps `Vary: Accept` on a
  # negotiated render. Left in place it would split a shared cache by Accept
  # string — the same damage `Vary: Authorization` would do, by another route.
  # A bare `MockRequest` sends no `Accept`, so both examples are needed.
  it "emits no Vary at all, negotiated or not" do
    _status, _body, plain = get_document
    _status, _body, negotiated = get_document(headers: { "HTTP_ACCEPT" => "application/json" })

    expect(plain["Vary"]).to be_nil
    expect(negotiated["Vary"]).to be_nil
  end

  it "serves ?v=<version> immutable, and a stale ?v= short-lived" do
    # The version is the ORIGIN's — {SchemaDocument.digest} — because the
    # api-catalog hangs one value on both description links.
    version = Kiosk::Server::SchemaDocument.digest

    _status, _body, fresh = get_document(path: "/kiosk/openapi.json?v=#{version}")
    expect(fresh["Cache-Control"]).to eq("max-age=31536000, public, immutable")

    status, body, stale = get_document(path: "/kiosk/openapi.json?v=deadbeef")
    expect(status).to eq(200)
    expect(body[:openapi]).to eq(Kiosk::Server::OpenApi::OPENAPI_VERSION)
    expect(stale["Cache-Control"]).to eq("max-age=60, public")
  end

  it "answers 304 to If-None-Match on its own ETag" do
    _status, _body, headers = get_document
    etag = headers["ETag"]

    status, _body, again = get_document(headers: { "HTTP_IF_NONE_MATCH" => etag })
    expect(status).to eq(304)
    expect(again["ETag"]).to eq(etag)

    status, = get_document(headers: { "HTTP_IF_NONE_MATCH" => %("stale") })
    expect(status).to eq(200)
  end

  # The ETag is this document's OWN bytes, not the shared `?v=` version: two
  # origins render different documents under one version, and an entity tag
  # names the representation at ONE url.
  it "carries an ETag distinct from the catalog's, because the bytes differ" do
    _status, _body, headers = get_document

    expect(headers["ETag"]).not_to eq(Kiosk::Server::SchemaDocument.etag)
  end

  it "describes the origin the request arrived at, not a memoized other one" do
    _status, first, = get_document
    _status, second, = get_document(path: "http://other.example/kiosk/openapi.json")

    expect(first[:servers].first[:url]).to eq("http://example.org/kiosk")
    expect(second[:servers].first[:url]).to eq("http://other.example/kiosk")
  end
end
