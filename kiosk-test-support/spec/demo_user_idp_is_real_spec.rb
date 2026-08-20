# frozen_string_literal: true

require "kiosk"

# T-066 regression: NO demo may ship a cleartext USER-IdP stub, and every demo
# that authenticates a human must do it with the real Devise adapter.
#
# THIS SPEC REPLACES `stub_user_idp_env_gate_spec.rb`, and the replacement is
# the point. That spec loaded the REAL shipped `user:u-<uuid>` bearer stub and
# proved it resolved to NO identity under a stubbed production Rails.env, while
# still accepting the forgery under development — because every driver and the
# e2e harness needed it to (K-555). The stub is deleted: the four demos that
# carried one (getgrocery, hoteling, skooti) and stylish's role-carrying
# `X-Staff-Session` SSO stand-in all authenticate humans through
# `kiosk-user-idp-devise` now, in every environment. An env gate on an arm that
# does not exist is not a property worth testing; that the arm cannot GROW BACK
# is.
#
# So this reads the shipped tree rather than a stubbed Rails.env:
#   - no demo, and not the e2e fixture host, ships a `stub_user_idp.rb`;
#   - every `c.user_idp =` in a demo initializer names the Devise adapter, with
#     no `Rails.env.local?` arm in front of it.
#
# It does NOT skip when the demos are absent. The old spec did, and K-502 caught
# it: after the files moved, the regression it guarded went QUIET rather than
# red. The demos ship in this repo; if they are not where this expects them, the
# spec has drifted and must say so.
REPO_ROOT  = File.expand_path("../..", __dir__)
DEMO_ROOTS = Dir.glob(File.join(REPO_ROOT, "kiosk-demo-*")).select { |d| File.directory?(d) }.sort
E2E_FIXTURES = File.join(REPO_ROOT, "e2e", "fixtures")

RSpec.describe "the demos' human channel is real Devise (T-066)" do
  it "finds the demo tree where it expects it (this spec never skips)" do
    expect(DEMO_ROOTS.size).to be >= 7,
                               "expected the operator demos beside kiosk-test-support, found " \
                               "#{DEMO_ROOTS.size} — this spec has drifted, fix the path"
    expect(Dir.exist?(E2E_FIXTURES)).to be(true), "expected e2e/fixtures at #{E2E_FIXTURES}"
  end

  it "ships no stub user-IdP anywhere" do
    strays = (DEMO_ROOTS.map { |d| File.join(d, "app/services/stub_user_idp.rb") } +
              [File.join(E2E_FIXTURES, "stub_user_idp.rb")]).select { |p| File.exist?(p) }
    expect(strays).to be_empty,
                      "a cleartext user-IdP stub is back: #{strays.join(", ")}. Humans " \
                      "authenticate through kiosk-user-idp-devise (T-066); a self-asserted " \
                      "`user:u-…` or `X-Staff-Session` parser lets anyone be anyone."
  end

  it "wires c.user_idp to the Devise adapter, unconditionally, wherever it is set" do
    wirings = DEMO_ROOTS.filter_map do |dir|
      initializer = File.join(dir, "config/initializers/kiosk.rb")
      next unless File.exist?(initializer)

      line = File.readlines(initializer).find { |l| l =~ /^\s*c\.user_idp\s*=/ }
      next unless line

      [File.basename(dir), line.strip]
    end

    # Every operator demo authenticates humans; only the KYC broker does not.
    expect(wirings.size).to be >= 7, "expected every operator demo to set c.user_idp, got #{wirings.inspect}"

    wirings.each do |demo, line|
      expect(line).to eq("c.user_idp = Kiosk::UserIdentityProviders::Devise.new"),
                      "#{demo} wires c.user_idp as `#{line}` — it must be the real Devise adapter " \
                      "with no dev-only arm (T-066)."
    end
  end
end
