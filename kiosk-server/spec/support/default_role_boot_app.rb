# frozen_string_literal: true

# The fresh-host boot behind spec/kiosk/server/default_role_boot_spec.rb (T-225)
# — run as a SUBPROCESS, never loaded into the RSpec process (same reasons as
# handler_registration_probe_app.rb: booting Rails in-process leaks
# Rails.logger and ActionDispatch::Flash into unrelated controller specs, and a
# real adopter's app boots in its own process anyway).
#
# It builds a THROWAWAY Rails app in a temp dir, configures Kiosk exactly as an
# operator's `config/initializers/kiosk.rb` would, boots it for real, and
# reports whether `Rails.application.initialize!` came back or raised.
#
# WHY A REAL BOOT AND NOT ONLY THE UNIT EXAMPLES. The condition is asserted in
# default_role_configuration_spec.rb; what THIS file proves is the other half —
# that the engine's `after_initialize` block actually RAISES on it, and that a
# correctly configured origin still comes up. A refusal nobody can show firing
# is a rule the tree only believes it has.
#
# Usage: ruby default_role_boot_app.rb <scenario>
# Scenarios (one per subprocess, because a Rails app boots once per process):
#
#   roles_without_default  a declared role vocabulary and no `registration_role`
#                          — the configuration T-225 makes unbootable.
#   roles_with_default     the shape all seven demos and the e2e fixture ship.
#   no_roles               no role vocabulary at all — ADR-0011's protected
#                          operator, which MUST boot exactly as before.

require "bundler/setup"
require "fileutils"
require "json"
require "tmpdir"
require "kiosk/server"

SCENARIO = ARGV.fetch(0)
ROOT     = Dir.mktmpdir("kiosk-default-role-boot")
at_exit { FileUtils.remove_entry(ROOT) if File.directory?(ROOT) }

app = Class.new(Rails::Application) do
  config.root             = ROOT
  config.eager_load       = false
  config.enable_reloading = false
  config.secret_key_base  = "default-role-boot"
  config.logger           = Logger.new(IO::NULL)
  config.hosts.clear
end
Object.const_set(:DefaultRoleBootApp, app)

Kiosk.configure do |c|
  c.issuer      = "http://localhost"
  c.user_model  = "User"
  c.signing_key = Kiosk::Server::SigningKey.generate

  case SCENARIO
  when "roles_without_default"
    c.roles = %i[customer owner]
  when "roles_with_default"
    c.roles             = %i[customer owner]
    c.registration_role = :customer
  when "no_roles"
    nil # the default: `roles` is [] and `registration_role` is unset
  else
    raise ArgumentError, "unknown scenario #{SCENARIO.inspect}"
  end
end

report =
  begin
    Rails.application.initialize!
    {
      "booted" => true,
      "roles" => Kiosk.configuration.roles.map(&:to_s),
      "registration_role" => Kiosk.configuration.registration_role&.to_s,
    }
  rescue StandardError => e
    { "booted" => false, "error_class" => e.class.name, "message" => e.message }
  end

puts JSON.generate(report)
