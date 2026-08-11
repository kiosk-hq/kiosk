# frozen_string_literal: true

require "kiosk"

# K-555 regression: the demos' cleartext USER-IdP stub must be UNREACHABLE in
# production. Sibling of the K-539 agent-stub env-gate spec.
#
# This loads the REAL shipped plaintext `user:u-<uuid>` bearer stub (skooti's
# copy — its `verify` is byte-identical across skooti / getgrocery / hoteling
# and the e2e fixture) and drives a forged, self-asserted `user:u-…` bearer
# through it under stubbed envs. It proves BOTH halves of the fix:
#   - production  → resolves to NO identity (→ the binding surface raises 401)
#   - development/test → still accepted (or every demo driver + e2e break)
# The over-the-wire production-config counterpart for the role-carrying
# X-Staff-Session variant lives in deploy/production-smoke.sh (stylish
# Assertion 6); the demos' script/redteam_suite.rb carry in-process beats too.
demo_lib      = File.expand_path("../../kiosk-demo-skooti/lib", __dir__)
stub_idp_path = File.join(demo_lib, "stub_user_idp.rb")
have_source   = File.exist?(stub_idp_path)
require stub_idp_path if have_source

RSpec.describe "StubUserIdp production env-gate (K-555)" do
  before { skip "demo user-IdP source not present (public CI without demos)" unless have_source }

  forged_bearer = "user:u-11111111-1111-4111-8111-111111111111"
  let(:request) { double("request", headers: { "Authorization" => forged_bearer }) }
  let(:idp)     { StubUserIdp.new }

  def with_env(name)
    env = double("Rails.env", local?: %w[development test].include?(name), to_s: name)
    stub_const("Rails", double("Rails", env: env))
  end

  it "REJECTS the forged self-asserted human bearer under production config" do
    with_env("production")
    expect(idp.verify(request)).to be_nil
  end

  it "ACCEPTS the forged human bearer under development (driver/e2e convenience)" do
    with_env("development")
    identity = idp.verify(request)
    expect(identity).not_to be_nil
    expect(identity.actor.to_s).to eq("human")
    expect(identity.role.to_s).to eq("customer")
    expect(identity.user_id).to eq("11111111-1111-4111-8111-111111111111")
  end

  it "ACCEPTS the forged human bearer under test (specs/e2e)" do
    with_env("test")
    expect(idp.verify(request)).not_to be_nil
  end

  it "returns nil under production for a Bearer-prefixed forgery too" do
    with_env("production")
    prefixed = double("request", headers: { "Authorization" => "Bearer #{forged_bearer}" })
    expect(idp.verify(prefixed)).to be_nil
  end
end
