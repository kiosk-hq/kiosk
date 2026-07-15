# frozen_string_literal: true

# DiscoveryController request specs (0.2 standards alignment, W1/W3).
#
# Like controller_auth_spec.rb: the controller guards itself behind
# `defined?(::ActionController::API)`, and spec_helper requires kiosk/server
# BEFORE actionpack is available — so this file pulls in actionpack and
# re-`load`s the controller to materialise the class. Dispatch goes through
# `ActionController::Metal.action(...)`, a plain Rack app — no Rails host.

require "action_controller"
require "rack/mock"
require "json"

load File.expand_path("../../../lib/kiosk/server/discovery_controller.rb", __dir__)

RSpec.describe "DiscoveryController" do
  def dispatch(action, path)
    status, headers, body = Kiosk::Server::DiscoveryController.action(action).call(
      Rack::MockRequest.env_for("https://api.acme.example#{path}"),
    )
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, headers, raw]
  end

  before do
    Kiosk.configure do |c|
      c.issuer = "https://api.acme.example"
      c.owner  = { name: "Acme Inc.", support: "support@acme.example" }
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
      expect(doc["auth_modes"]).to eq(["kiosk-pop"])
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
      Kiosk::Server::Queries.register("catalog") { [] }
      status, headers, raw = dispatch(:api_catalog, "/.well-known/api-catalog")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to include("application/linkset+json")
      # The RFC 9727 profile parameter identifies the api-catalog media type.
      expect(headers["Content-Type"]).to include('profile="https://www.rfc-editor.org/info/rfc9727"')
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      doc = JSON.parse(raw)
      items = doc.dig("linkset", 0, "item")
      expect(items).not_to be_empty
      # The schema endpoint is tagged as the machine-readable service-desc.
      schema = items.find { |i| i["href"].end_with?("/schema") }
      expect(schema["rel"]).to eq("service-desc")
    end
  end
end
