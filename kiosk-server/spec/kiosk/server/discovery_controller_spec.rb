# frozen_string_literal: true

# DiscoveryController request specs (0.2 standards alignment, W1/W3).
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host.

require "rack/mock"
require "json"

RSpec.describe "DiscoveryController" do
  def dispatch(action, path, **opts)
    status, headers, body = Kiosk::Server::DiscoveryController.action(action).call(
      Rack::MockRequest.env_for("https://api.acme.example#{path}", **opts),
    )
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, headers, raw]
  end

  before do
    Kiosk.configure do |c|
      c.issuer = "https://api.acme.example"
      c.owner  = { name: "Acme Inc.", support: "support@acme.example" }
      # Serve `pay` so the discovery surfaces advertise the AP2/payment
      # directives (pay-conditional). WellKnown gates them on
      # `pay` ∈ capabilities, so a payment_provider must be
      # configured for `Protocols: ap2` / `Payments: required` to appear.
      c.payment_provider = Object.new
    end
  end

  describe "GET /agents.txt" do
    it "returns 200 text/plain with the directives + CORS" do
      status, headers, raw = dispatch(:agents_txt, "/agents.txt")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/plain; charset=utf-8")
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(raw).to include("Protocols: ap2")
      expect(raw).to include("Authorization: agent-auth")
      # base_url comes from the request
      expect(raw).to include("# JSON: https://api.acme.example/agents.json")
    end
  end

  describe "GET /agents.json" do
    it "returns 200 application/json with the required keys + CORS" do
      status, headers, raw = dispatch(:agents_json, "/agents.json")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to include("application/json")
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      doc = JSON.parse(raw)
      expect(doc["version"]).to eq("1.0")
      expect(doc.dig("site", "url")).to eq("https://api.acme.example")
      expect(doc.dig("authorization", "discovery")).to eq("/.well-known/agent-configuration")
    end
  end

  describe "GET /.well-known/agent-configuration" do
    it "returns 200 application/json listing the auth endpoints" do
      status, headers, raw = dispatch(:agent_configuration, "/.well-known/agent-configuration")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to include("application/json")
      doc = JSON.parse(raw)
      expect(doc["issuer"]).to eq("https://api.acme.example")
      expect(doc.dig("endpoints", "challenge")).to eq("https://api.acme.example/kiosk/auth/challenge")
      expect(doc["auth_modes"]).to eq(["kiosk-pop", "user-claimed", "link-code"])
      expect(doc["auth_md"]).to eq("https://api.acme.example/auth.md")
    end
  end

  describe "GET /auth.md" do
    it "returns 200 text/markdown with the auth.md body + CORS" do
      status, headers, raw = dispatch(:auth_md, "/auth.md")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/markdown; charset=utf-8")
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      # Byte-identical to the renderer (single generator seam).
      expect(raw).to eq(Kiosk::Server::WellKnown.auth_md(base_url: "https://api.acme.example"))
      expect(raw).to include("## Pick a method")
    end
  end

  describe "GET /.well-known/kiosk.json" do
    it "returns 200 application/json byte-identical to WellKnown.build_json" do
      status, headers, raw = dispatch(:kiosk_json, "/.well-known/kiosk.json")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to include("application/json")
      # Regression guard: the derived alias must be byte-for-byte the current
      # bespoke document.
      expected = Kiosk::Server::WellKnown.build_json(base_url: "https://api.acme.example")
      expect(raw).to eq(expected)
    end
  end

  describe "GET /.well-known/api-catalog" do
    it "returns 200 application/linkset+json (RFC 9727) with a non-empty item list" do
      # A registered query makes `schema` a live capability, so the linkset
      # catalogues the wire endpoints (not just the discovery companion).
      declare_query("catalog")
      status, headers, raw = dispatch(:api_catalog, "/.well-known/api-catalog")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to include("application/linkset+json")
      # The RFC 9727 profile parameter identifies the api-catalog media type.
      expect(headers["Content-Type"]).to include('profile="https://www.rfc-editor.org/info/rfc9727"')
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      doc = JSON.parse(raw)
      items = doc.dig("linkset", 0, "item")
      expect(items).not_to be_empty
      # The schema endpoint is tagged as the machine-readable service-desc,
      # at the VERSIONED url (K-804) — a pointer document links the url that
      # is safe to cache, not the bare path.
      schema = items.find { |i| i["href"].start_with?("https://api.acme.example/kiosk/schema") }
      expect(schema["href"])
        .to eq("https://api.acme.example/kiosk/schema?v=#{Kiosk::Server::SchemaDocument.digest}")
      expect(schema["rel"]).to eq("service-desc")
    end
  end

  # ─── the cache policy of the POINTER documents ───────────────────────────
  #
  # `max-age=60` (Phil, 2026-08-19), not because a minute is efficient but
  # because a minute is how long an operator must live with the previous
  # document after a deploy. The load these documents would otherwise carry is
  # carried by the immutable `?v=` url they point at.
  describe "the public cache policy" do
    it "serves the three pointer documents public, one minute" do
      declare_query("catalog")
      %i[agents_json kiosk_json api_catalog].each do |action|
        _status, headers, = dispatch(action, "/x")
        expect(headers["Cache-Control"]).to eq(Kiosk::Server::Headers::PUBLIC_SHORT)
        expect(headers["Cache-Control"]).to eq("max-age=60, public")
      end
    end

    # «А Vary зачем? Это паблик, общедоступная инфа.» — Phil, 2026-08-19.
    # None of these six reads a request header, so none of them varies. Rails
    # disagrees unless stopped: `_set_vary_header` stamps `Vary: Accept` on
    # any render negotiated from a non-blank `Accept`, which is what a real
    # client sends and what a bare MockRequest does NOT — so the negotiated
    # half is the half that matters.
    it "emits no Vary on any of the six, negotiated or not" do
      declare_query("catalog")
      actions = { agents_txt: "/agents.txt", agents_json: "/agents.json",
                  agent_configuration: "/.well-known/agent-configuration",
                  kiosk_json: "/.well-known/kiosk.json",
                  api_catalog: "/.well-known/api-catalog", auth_md: "/auth.md" }
      actions.each do |action, path|
        _status, plain, = dispatch(action, path)
        _status, negotiated, = dispatch(action, path, "HTTP_ACCEPT" => "application/json")
        expect(plain["Vary"]).to be_nil, "#{action} varies (unnegotiated)"
        expect(negotiated["Vary"]).to be_nil, "#{action} varies (Accept: application/json)"
      end
    end
  end
end
