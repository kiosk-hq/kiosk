# frozen_string_literal: true

require "kiosk"

# T-104 regression: NO demo may ship a cleartext AGENT-IdP stub, and no demo
# may override the engine's own agent-IdP at all.
#
# THIS SPEC REPLACES `jwt_or_stub_idp_env_gate_spec.rb`, and the replacement is
# the point — the same move T-066 made on the human side. That spec loaded the
# REAL shipped composite, drove a forged `agent:u-…:a-…:r-owner` bearer through
# it, and proved the parser resolved to NO identity under a stubbed production
# `Rails.env` while still ACCEPTING the forgery under development, because
# every driver and the e2e harness needed it to (K-539). The parser is deleted:
# assistants authenticate with the kiosk-pop JWTs the engine itself mints, and
# `Kiosk::Server::IdentityResolution` already falls back to the adapter that
# verifies them. An env gate on an arm that does not exist is not a property
# worth testing; that the arm cannot GROW BACK is.
#
# So this reads the shipped tree rather than a stubbed `Rails.env`:
#   - no demo, and not the e2e fixture host, ships a `stub_idp.rb` or a
#     `jwt_or_stub_idp.rb`;
#   - no demo initializer sets `c.agent_idp` — the engine's default is the
#     whole mechanism, and an override is how a second one gets in.
#
# That the default REALLY IS the kiosk-pop verifier, and that it refuses the
# forged bearer in every environment rather than under a gated arm, is asserted
# where the engine lives: kiosk-server's identity_resolution_spec.rb. This gem
# does not depend on kiosk-server, and reaching for it here would be the only
# reason to.
#
# It does NOT skip when the demos are absent (K-502: the old user-side spec did,
# and after the files moved its regression went QUIET rather than red).
AGENT_REPO_ROOT   = File.expand_path("../..", __dir__)
AGENT_DEMO_ROOTS  = Dir.glob(File.join(AGENT_REPO_ROOT, "kiosk-demo-*")).select { |d| File.directory?(d) }.sort
AGENT_E2E_FIXTURES = File.join(AGENT_REPO_ROOT, "e2e", "fixtures")

RSpec.describe "the demos' agent channel is the engine's own kiosk-pop verifier (T-104)" do
  it "finds the demo tree where it expects it (this spec never skips)" do
    expect(AGENT_DEMO_ROOTS.size).to be >= 7,
                                     "expected the operator demos beside kiosk-test-support, found " \
                                     "#{AGENT_DEMO_ROOTS.size} — this spec has drifted, fix the path"
    expect(Dir.exist?(AGENT_E2E_FIXTURES)).to be(true), "expected e2e/fixtures at #{AGENT_E2E_FIXTURES}"
  end

  it "ships no self-asserted agent-bearer parser anywhere" do
    names  = %w[stub_idp.rb jwt_or_stub_idp.rb]
    strays = (AGENT_DEMO_ROOTS.flat_map { |d| names.map { |n| File.join(d, "app/services", n) } } +
              names.map { |n| File.join(AGENT_E2E_FIXTURES, n) }).select { |p| File.exist?(p) }
    expect(strays).to be_empty,
                      "a cleartext agent-IdP stub is back: #{strays.join(", ")}. Assistants " \
                      "authenticate with the kiosk-pop JWT the engine minted (T-104); a " \
                      "self-asserted `agent:u-…:a-…:r-…` parser lets anyone be any agent at any " \
                      "role — that was K-539, and an env gate in front of it is not the fix."
  end

  it "leaves c.agent_idp unset in every demo and in the e2e fixture host" do
    initializers = AGENT_DEMO_ROOTS.map { |d| File.join(d, "config/initializers/kiosk.rb") } +
                   [File.join(AGENT_E2E_FIXTURES, "initializer_kiosk.rb")]
    overrides = initializers.select { |f| File.exist?(f) }.filter_map do |f|
      line = File.readlines(f).find { |l| l =~ /^\s*c\.agent_idp\s*=/ }
      [f.sub("#{AGENT_REPO_ROOT}/", ""), line.strip] if line
    end
    expect(overrides).to be_empty,
                         "these set c.agent_idp: #{overrides.inspect}. The engine's " \
                         "DefaultAgentIdp verifies the tokens the engine mints, so a demo needs " \
                         "no override — and an override is where a second, weaker verifier gets " \
                         "in. Set it only to front an EXTERNAL agent-identity issuer."
  end

end
