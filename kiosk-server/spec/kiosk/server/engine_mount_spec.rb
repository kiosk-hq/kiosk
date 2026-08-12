# frozen_string_literal: true

# The one-line adoption proof (T-055 slice of K-495; closes K-505): a fresh
# Rails app whose ONLY Kiosk line is
#
#   mount Kiosk::Server::Engine => "/kiosk"
#
# must serve the full surface — wire + auth plane + JWKS + KYC + binding
# ceremony under the mount, and the ROOT-relative discovery documents
# (/agents.txt, /agents.json, /auth.md, /.well-known/*) installed by the
# engine's routes.append initializer. Three properties are pinned here:
#
#   1. mounted        → full surface, end-to-end through the real Rack stack;
#   2. NOT mounted    → the gem is inert: loading it adds NO routes (today's
#                       demos hand-draw everything and must stay byte-identical
#                       in behaviour until T-057 migrates them);
#   3. mounted + hand-drawn duplicates → the HOST's hand-drawn line wins
#                       (config/routes.rb precedes routes.append; Rails
#                       dispatches the first match), so a half-migrated app
#                       cannot break.
#
# The probe app is a real, booted Rails::Application (one per process — Rails
# allows no second), so the engine's initializers run exactly as they do in a
# host: middleware injection and the root-discovery append registration both
# happen through the boot path, not through test doubles.

require "rack/mock"

module EngineMountProbe
  # Boots the probe application once per process, lazily, so suite runs that
  # never execute this file pay nothing. Routes are (re)drawn per example —
  # RouteSet#draw clears and re-finalizes, re-running append blocks, which is
  # exactly the dev-mode reload semantics.
  def self.app
    @app ||= begin
      probe = Class.new(Rails::Application) do
        config.eager_load = false
        config.hosts.clear
        config.secret_key_base = "engine-mount-spec"
        config.logger = Logger.new(IO::NULL)
      end
      Object.const_set(:KioskEngineMountProbeApp, probe)
      probe.initialize!
      Rails.application
    end
  end
end

RSpec.describe "mount Kiosk::Server::Engine (the one-line surface)" do
  let(:app) { EngineMountProbe.app }

  def draw(&block)
    block ||= proc {}
    app.routes.draw(&block)
  end

  def request(method, path, body: nil)
    env = Rack::MockRequest.env_for(
      "http://localhost#{path}",
      method: method,
      input: body,
    )
    status, headers, raw = app.call(env)
    payload = +""
    raw.each { |chunk| payload << chunk }
    raw.close if raw.respond_to?(:close)
    [status, headers, payload]
  end

  before do
    Kiosk.configure do |c|
      c.issuer      = "http://localhost"
      c.user_model  = "User"
      c.signing_key = Kiosk::Server::SigningKey.generate
    end
    Kiosk::Server::Queries.register(
      "ping", ->(_args, _identity) { [] },
      description: "probe query",
    )
  end

  # Routes drawn by one example must not leak into the next file's examples.
  after { draw }

  # Booting the probe app sets Rails.logger process-wide (to this file's null
  # logger). The rest of this suite relies on the gem's documented posture
  # that Rails.logger is nil until a host app boots — pop_verifier_spec
  # captures the Kernel#warn fallback of the audience-mismatch diagnostic —
  # so restore the invariant once this group is done. (Rails.application
  # itself cannot be un-booted; nothing else in the suite reads it.)
  after(:context) { Rails.logger = nil }

  context "when the engine is mounted (fresh app, one line)" do
    before { draw { mount Kiosk::Server::Engine => "/kiosk" } }

    it "serves the root discovery documents end-to-end" do
      status, _headers, body = request("GET", "/agents.txt")
      expect(status).to eq(200)
      expect(body).to include("http://localhost/agents.json")

      status, _headers, body = request("GET", "/agents.json")
      expect(status).to eq(200)
      expect(JSON.parse(body).dig("x-kiosk", "wire", "schema")).to eq("/kiosk/schema")

      status, _headers, body = request("GET", "/.well-known/kiosk.json")
      expect(status).to eq(200)
      expect(JSON.parse(body).dig("kiosk", "capabilities")).to include("query")

      status, _headers, body = request("GET", "/.well-known/agent-configuration")
      expect(status).to eq(200)
      expect(JSON.parse(body)).to be_a(Hash)

      status, headers, _body = request("GET", "/.well-known/api-catalog")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to include("linkset+json")

      status, headers, _body = request("GET", "/auth.md")
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to include("markdown")
    end

    it "serves JWKS under the mount, stamped by the auto-injected middleware" do
      status, headers, body = request("GET", "/kiosk/.well-known/jwks.json")
      expect(status).to eq(200)
      expect(JSON.parse(body).fetch("keys")).not_to be_empty
      # HeadersMiddleware was injected by the engine initializer at boot; it
      # stamps mount-prefixed responses (Rack 3 downcases header names).
      expect(headers.keys.map(&:downcase)).to include("kiosk-server-version")
    end

    it "routes the wire verbs into WireController (401 envelope, not 404)" do
      %w[schema query run pay].each do |verb|
        method = verb == "schema" ? "GET" : "POST"
        status, _headers, body = request(method, "/kiosk/#{verb}")
        expect(status).to eq(401), "#{verb}: expected 401, got #{status}"
        expect(JSON.parse(body).dig("error", "code")).to eq("unauthenticated")
      end
    end

    it "routes the kiosk-pop auth plane into AuthController" do
      # A malformed register/login/revoke answers with the wire envelope —
      # reaching the controller at all is what this route proof needs.
      %w[register login revoke].each do |action|
        status, _headers, body = request("POST", "/kiosk/auth/#{action}")
        expect(status).to be_between(400, 401), "#{action}: got #{status}"
        expect(JSON.parse(body)).to have_key("error")
      end
      status, _headers, body = request("GET", "/kiosk/auth/challenge")
      expect(status).to eq(400)
      expect(JSON.parse(body)).to have_key("error")
    end

    it "routes the KYC attestation endpoint" do
      status, _headers, body = request("POST", "/kiosk/agents/kyc")
      expect(status).to eq(401)
      expect(JSON.parse(body)).to have_key("error")
    end

    it "routes the binding ceremony: claim wire + link surface + HTML pages" do
      status, _headers, body = request("POST", "/kiosk/oauth/device_authorization")
      expect(status).to eq(400)
      expect(JSON.parse(body)).to have_key("error")

      status, _headers, _body = request("POST", "/kiosk/oauth/token")
      expect(status).to eq(400)

      status, _headers, _body = request("GET", "/kiosk/oauth/device/verify")
      expect(status).to eq(401) # no signed-in human; the page demands one

      %w[link claim unlink].each do |action|
        status, _headers, body = request("POST", "/kiosk/auth/#{action}")
        expect(status).to be_between(400, 401), "#{action}: got #{status}"
        expect(JSON.parse(body)).to have_key("error")
      end

      status, _headers, _body = request("GET", "/kiosk/auth/assistants")
      expect(status).to eq(401) # ditto: account-holder page

      # The page's own forms post to these three; the engine must route them
      # all (update was missing from the pre-T-055 drawer).
      %w[link update unlink].each do |action|
        status, _headers, _body = request("POST", "/kiosk/auth/assistants/#{action}")
        expect(status).to eq(401), "assistants/#{action}: got #{status}"
      end
    end
  end

  context "when the engine is NOT mounted" do
    before { draw }

    it "installs no root discovery routes — loading the gem is inert" do
      status, = request("GET", "/agents.txt")
      expect(status).to eq(404)
      status, = request("GET", "/.well-known/kiosk.json")
      expect(status).to eq(404)
    end

    it "serves no wire routes" do
      status, = request("GET", "/kiosk/schema")
      expect(status).to eq(404)
    end

    it "reports itself unmounted" do
      expect(Kiosk::Server::Engine.mounted_in?(app.routes)).to be(false)
    end
  end

  context "when the host BOTH mounts the engine and hand-draws the same paths" do
    # A stub distinguishable from the shipped DiscoveryController, so the
    # winner of a double-draw is observable.
    before do
      stub = Class.new(ActionController::API) do
        def hand = render(plain: "HAND-DRAWN")
      end
      stub_const("HandDrawnController", stub)

      draw do
        get "/agents.txt",   to: "hand_drawn#hand"
        get "/kiosk/schema", to: "hand_drawn#hand"
        mount Kiosk::Server::Engine => "/kiosk"
      end
    end

    it "the hand-drawn ROOT route wins: config/routes.rb precedes routes.append" do
      status, _headers, body = request("GET", "/agents.txt")
      expect(status).to eq(200)
      expect(body).to eq("HAND-DRAWN")
    end

    it "the hand-drawn MOUNT-PREFIXED route wins when drawn before the mount" do
      status, _headers, body = request("GET", "/kiosk/schema")
      expect(status).to eq(200)
      expect(body).to eq("HAND-DRAWN")
    end

    it "paths only the engine draws still resolve through the mount" do
      status, _headers, body = request("GET", "/agents.json")
      expect(status).to eq(200)
      expect(JSON.parse(body).dig("x-kiosk", "wire", "schema")).to eq("/kiosk/schema")

      status, = request("GET", "/kiosk/.well-known/jwks.json")
      expect(status).to eq(200)
    end
  end
end
