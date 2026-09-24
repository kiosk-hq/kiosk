# frozen_string_literal: true

# T-225 — the refusal, against a REAL booted Rails application.
#
# default_role_configuration_spec.rb asserts the CONDITION on the engine class.
# This file asserts the consequence: that the engine's `after_initialize` block
# turns that condition into a refused boot, and that neither supported shape is
# touched by it. Out of process, one boot per scenario; see the app's header.

require "open3"

module DefaultRoleBoot
  APP = File.expand_path("../../support/default_role_boot_app.rb", __dir__)

  def self.report(scenario)
    @reports ||= {}
    @reports[scenario] ||= begin
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, APP, scenario)
      # The app reports a refused boot as DATA, on stdout, at exit 0 — a
      # non-zero exit here means the fixture itself broke, which must not be
      # read as "the engine refused".
      unless status.success?
        raise "default-role boot app (#{scenario}) failed (#{status.exitstatus}):\n" \
              "--- stdout ---\n#{stdout}\n--- stderr ---\n#{stderr}"
      end
      JSON.parse(stdout)
    end
  end
end

RSpec.describe "the default role in a booted app" do
  def boot(scenario) = DefaultRoleBoot.report(scenario)

  context "an origin that declares roles and configures no default" do
    it "does not come up at all" do
      expect(boot("roles_without_default")["booted"]).to be(false)
    end

    it "refuses with a ConfigurationError, not with whatever raised first" do
      expect(boot("roles_without_default")["error_class"])
        .to eq("Kiosk::Server::Errors::ConfigurationError")
    end

    it "names the setting the operator has to add" do
      expect(boot("roles_without_default")["message"]).to include("registration_role")
    end

    it "names the other supported shape too, so the message has both exits" do
      expect(boot("roles_without_default")["message"]).to include("c.roles = []")
    end
  end

  context "an origin that declares roles AND a default" do
    it "boots — this is what all seven demos and the e2e fixture configure" do
      expect(boot("roles_with_default")["booted"]).to be(true)
    end

    it "boots with the default it was given" do
      expect(boot("roles_with_default")["registration_role"]).to eq("customer")
    end
  end

  # ADR-0011's protected operator. The amendment narrows that decision to
  # origins that declare a role vocabulary; this one still boots with no role
  # anywhere, exactly as it did before.
  context "an origin that declares no roles at all" do
    it "boots" do
      expect(boot("no_roles")["booted"]).to be(true)
    end

    it "boots with no role vocabulary and no default — nothing was made mandatory" do
      expect(boot("no_roles")["roles"]).to eq([])
      expect(boot("no_roles")["registration_role"]).to be_nil
    end
  end
end
