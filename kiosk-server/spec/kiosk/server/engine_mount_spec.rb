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
# The probe app is a real, booted Rails::Application run ONCE as a SUBPROCESS
# (spec/support/engine_mount_probe_app.rb — see its header for why a
# subprocess: booting Rails inside the suite process leaks Rails.logger and
# ActionDispatch::Flash into unrelated controller specs). The engine's
# initializers run through the genuine boot path; this file asserts on the
# probe's JSON report.

require "open3"

module EngineMountProbe
  PROBE = File.expand_path("../../support/engine_mount_probe_app.rb", __dir__)

  def self.report
    @report ||= begin
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, PROBE)
      unless status.success?
        raise "engine mount probe app failed (#{status.exitstatus}):\n" \
              "--- stdout ---\n#{stdout}\n--- stderr ---\n#{stderr}"
      end
      JSON.parse(stdout)
    end
  end
end

RSpec.describe "mount Kiosk::Server::Engine (the one-line surface)" do
  def probe(scenario, key = nil)
    scenario_report = EngineMountProbe.report.fetch(scenario)
    key ? scenario_report.fetch(key) : scenario_report
  end

  context "when the engine is mounted (fresh app, one line)" do
    it "reports itself mounted" do
      expect(probe("mounted", "mounted_in?")).to be(true)
    end

    it "serves the root discovery documents end-to-end" do
      res = probe("mounted", "GET /agents.txt")
      expect(res["status"]).to eq(200)
      expect(res["body"]).to include("http://localhost/agents.json")

      res = probe("mounted", "GET /agents.json")
      expect(res["status"]).to eq(200)
      expect(JSON.parse(res["body"]).dig("x-kiosk", "schema"))
        .to eq("/kiosk/schema")

      res = probe("mounted", "GET /.well-known/kiosk.json")
      expect(res["status"]).to eq(200)
      expect(JSON.parse(res["body"]).dig("kiosk", "capabilities")).to include("queries")

      res = probe("mounted", "GET /.well-known/agent-configuration")
      expect(res["status"]).to eq(200)
      expect(JSON.parse(res["body"])).to be_a(Hash)

      res = probe("mounted", "GET /.well-known/api-catalog")
      expect(res["status"]).to eq(200)
      expect(res["headers"]["content-type"]).to include("linkset+json")

      res = probe("mounted", "GET /auth.md")
      expect(res["status"]).to eq(200)
      expect(res["headers"]["content-type"]).to include("markdown")
    end

    it "serves JWKS under the mount, stamped by the auto-injected middleware" do
      res = probe("mounted", "GET /kiosk/.well-known/jwks.json")
      expect(res["status"]).to eq(200)
      expect(JSON.parse(res["body"]).fetch("keys")).not_to be_empty
      # HeadersMiddleware was injected by the engine initializer at boot; it
      # stamps mount-prefixed responses.
      expect(res["headers"]).to have_key("kiosk-server-version")
    end

    it "routes the two RESERVED wire endpoints into WireController (401 problem, not 404)" do
      # Two, not four: `POST <endpoint>/{query,run}` were DELETED at the 0.4
      # cutover (T-074 = A) — see the example below for what answers there now.
      {
        "GET /kiosk/schema" => "schema",
        "POST /kiosk/pay"   => "pay",
      }.each do |request_line, verb|
        res = probe("mounted", request_line)
        expect(res["status"]).to eq(401), "#{verb}: expected 401, got #{res["status"]}"
        expect(res["headers"]["content-type"]).to include("application/problem+json")
        expect(JSON.parse(res["body"])["code"]).to eq("unauthenticated")
      end
    end

    it "has no 0.3 multiplexed wire left: /query and /run are unregistered verb NAMES" do
      # Anonymous, these answer 401 like every other single-segment path under
      # the mount, which proves nothing. WITH a Bearer token the per-verb wire
      # gets past its first gate and answers what it answers for any name
      # nobody declared — `404 not_found`, as an RFC 9457 problem document,
      # with no tombstone and no hint that a wire ever lived there.
      ["POST /kiosk/query (bearer)", "POST /kiosk/run (bearer)"].each do |request_line|
        res = probe("mounted", request_line)
        expect(res["status"]).to eq(404), "#{request_line}: got #{res["status"]}"
        expect(res["headers"]["content-type"]).to include("application/problem+json")

        body = JSON.parse(res["body"])
        expect(body["code"]).to eq("not_found")
        expect(body).not_to have_key("ok")
        expect(body).not_to have_key("error")
      end
    end

    it "routes the kiosk-pop auth plane into AuthController" do
      # A malformed register/login/revoke answers with the wire's RFC 9457
      # problem document — reaching the controller at all is what this route
      # proof needs, and a top-level `code` is what says a Kiosk controller
      # answered rather than the router.
      %w[register login revoke].each do |action|
        res = probe("mounted", "POST /kiosk/auth/#{action}")
        expect(res["status"]).to be_between(400, 401), "#{action}: got #{res["status"]}"
        expect(JSON.parse(res["body"])).to have_key("code")
      end
      res = probe("mounted", "GET /kiosk/auth/challenge")
      expect(res["status"]).to eq(400)
      expect(JSON.parse(res["body"])).to have_key("code")
    end

    it "routes the KYC attestation endpoint" do
      res = probe("mounted", "POST /kiosk/agents/kyc")
      expect(res["status"]).to eq(401)
      expect(JSON.parse(res["body"])["code"]).to eq("unauthenticated")
    end

    it "routes the binding ceremony: claim wire + link surface + HTML pages" do
      res = probe("mounted", "POST /kiosk/oauth/device_authorization")
      expect(res["status"]).to eq(400)
      expect(JSON.parse(res["body"])).to have_key("error")

      expect(probe("mounted", "POST /kiosk/oauth/token")["status"]).to eq(400)

      # No signed-in human; the two HTML pages demand one.
      expect(probe("mounted", "GET /kiosk/oauth/device/verify")["status"]).to eq(401)
      expect(probe("mounted", "GET /kiosk/auth/assistants")["status"]).to eq(401)

      %w[link claim unlink].each do |action|
        res = probe("mounted", "POST /kiosk/auth/#{action}")
        expect(res["status"]).to be_between(400, 401), "#{action}: got #{res["status"]}"
        # The Kiosk-native half of the ceremony answers the 0.4 problem
        # document (top-level `code`); the OAuth endpoints above keep the
        # RFC 8628 `{error, error_description}` shape, which is why only they
        # are asserted with `error`.
        expect(JSON.parse(res["body"])).to have_key("code")
      end

      # The page's own forms post to these three; the engine must route them
      # all (update was missing from the pre-T-055 drawer).
      %w[link update unlink].each do |action|
        res = probe("mounted", "POST /kiosk/auth/assistants/#{action}")
        expect(res["status"]).to eq(401), "assistants/#{action}: got #{res["status"]}"
      end
    end
  end

  context "when the engine is NOT mounted" do
    it "installs no root discovery routes — loading the gem is inert" do
      expect(probe("unmounted", "GET /agents.txt")["status"]).to eq(404)
      expect(probe("unmounted", "GET /.well-known/kiosk.json")["status"]).to eq(404)
    end

    it "serves no wire routes" do
      expect(probe("unmounted", "GET /kiosk/schema")["status"]).to eq(404)
    end

    it "reports itself unmounted" do
      expect(probe("unmounted", "mounted_in?")).to be(false)
    end
  end

  context "when the host BOTH mounts the engine and hand-draws the same paths" do
    it "the hand-drawn ROOT route wins: config/routes.rb precedes routes.append" do
      res = probe("double_draw", "GET /agents.txt")
      expect(res["status"]).to eq(200)
      expect(res["body"]).to eq("HAND-DRAWN")
    end

    it "the hand-drawn MOUNT-PREFIXED route wins when drawn before the mount" do
      res = probe("double_draw", "GET /kiosk/schema")
      expect(res["status"]).to eq(200)
      expect(res["body"]).to eq("HAND-DRAWN")
    end

    it "paths only the engine draws still resolve through the mount" do
      res = probe("double_draw", "GET /agents.json")
      expect(res["status"]).to eq(200)
      expect(JSON.parse(res["body"]).dig("x-kiosk", "schema"))
        .to eq("/kiosk/schema")

      expect(probe("double_draw", "GET /kiosk/.well-known/jwks.json")["status"]).to eq(200)
    end
  end
end
