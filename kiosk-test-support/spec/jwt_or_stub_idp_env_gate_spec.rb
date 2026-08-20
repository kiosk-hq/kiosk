# frozen_string_literal: true

require "kiosk"

# K-539 regression: the demos' cleartext identity stub must be UNREACHABLE in
# production.
#
# This loads the REAL shipped demo composite IdP (stylish's copy, under
# app/services since K-502 — its `verify`
# is byte-identical across all seven demos + the e2e fixture) and drives a
# forged, self-asserted `agent:u-…:a-…:r-owner` bearer through it under stubbed
# envs. It proves BOTH halves of the fix:
#   - production  → resolves to NO identity (→ the wire raises 401)
#   - development/test → still accepted (or every demo driver + e2e break)
# The over-the-wire production-config counterpart lives in
# deploy/production-smoke.sh (Assertion 5) and skooti's script/redteam_suite.rb.
demo_services  = File.expand_path("../../kiosk-demo-stylish/app/services", __dir__)
stub_idp_path  = File.join(demo_services, "stub_idp.rb")
composite_path = File.join(demo_services, "jwt_or_stub_idp.rb")
have_sources   = File.exist?(stub_idp_path) && File.exist?(composite_path)
if have_sources
  require stub_idp_path
  require composite_path
end

RSpec.describe "JwtOrStubIdp production env-gate (K-539)" do
  before { skip "demo IdP source not present (public CI without demos)" unless have_sources }

  forged_bearer = "agent:u-11111111-1111-4111-8111-111111111111:a-forged:r-owner"
  let(:request) { double("request", headers: { "Authorization" => "Bearer #{forged_bearer}" }) }

  def with_env(name)
    env = double("Rails.env", local?: %w[development test].include?(name), to_s: name)
    stub_const("Rails", double("Rails", env: env))
  end

  context "with a stub wired (as the initializers do in dev/test)" do
    let(:idp) { JwtOrStubIdp.new(stub: StubIdp.new) }

    it "REJECTS the forged self-asserted bearer under production config" do
      with_env("production")
      expect(idp.verify(request)).to be_nil
    end

    it "ACCEPTS the forged bearer under development (driver/e2e convenience)" do
      with_env("development")
      identity = idp.verify(request)
      expect(identity).not_to be_nil
      expect(identity.role.to_s).to eq("owner")
      expect(identity.actor.to_s).to eq("agent")
    end

    it "ACCEPTS the forged bearer under test (specs/e2e)" do
      with_env("test")
      expect(idp.verify(request)).not_to be_nil
    end
  end

  context "with a nil stub (as the initializers construct in production)" do
    let(:idp) { JwtOrStubIdp.new(stub: nil) }

    it "returns nil under production without raising" do
      with_env("production")
      expect(idp.verify(request)).to be_nil
    end

    it "returns nil under development without raising (no stub to call)" do
      with_env("development")
      expect(idp.verify(request)).to be_nil
    end
  end
end
