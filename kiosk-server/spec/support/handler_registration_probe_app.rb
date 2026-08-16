# frozen_string_literal: true

# The fresh-host probe behind spec/kiosk/server/handler_registration_boot_spec.rb
# — run as a SUBPROCESS, never loaded into the RSpec process (same reasons as
# engine_mount_probe_app.rb: booting Rails in-process leaks Rails.logger and
# ActionDispatch::Flash into unrelated controller specs, and a fresh adopter's
# app boots in its own process anyway).
#
# It builds a THROWAWAY Rails app in a temp dir with one handler controller in
# `app/controllers/kiosk/`, boots it for real, and reports what the registry
# holds — the only thing `GET <mount>/schema`, the wire's name lookup and the
# discovery documents' `capabilities` are ever computed from.
#
# Usage: ruby handler_registration_probe_app.rb <scenario>
# Scenarios (one per subprocess, because a Rails app boots once per process):
#
#   development             eager_load=false + `c.handlers` — the case that was
#                           BROKEN: nothing references a handler controller, so
#                           without the engine's to_prepare the catalog is
#                           empty. Then a real reload cycle three times over:
#                           an EDITED description, an ADDED verb, a REMOVED one.
#   development_undeclared  eager_load=false, handlers NOT declared — pins that
#                           the declaration is what registers, not luck.
#   production              eager_load=true, handlers NOT declared — the path
#                           that already worked and must keep working untouched.
#   production_declared     eager_load=true AND declared — no double vision.

require "bundler/setup"
require "fileutils"
require "json"
require "tmpdir"
require "kiosk/server"

SCENARIO = ARGV.fetch(0)
ROOT     = Dir.mktmpdir("kiosk-handler-probe")
at_exit { FileUtils.remove_entry(ROOT) if File.directory?(ROOT) }

CONTROLLER = File.join(ROOT, "app/controllers/kiosk/probe_controller.rb")
FileUtils.mkdir_p(File.dirname(CONTROLLER))

# Generation 1 of the operator's handler controller: two verbs.
def write_controller(verbs:, browse_description: "Generation 1 description.")
  body = +"class Kiosk::ProbeController < ActionController::Base\n  include Kiosk::Query\n"
  if verbs.include?(:browse)
    body << "\n  description #{browse_description.inspect}\n  def probe_browse\n    render json: []\n  end\n"
  end
  if verbs.include?(:detail)
    body << "\n  description \"The second verb.\"\n  def probe_detail\n    render json: []\n  end\n"
  end
  if verbs.include?(:added)
    body << "\n  description \"Added while the app was running.\"\n  def probe_added\n    render json: []\n  end\n"
  end
  body << "end\n"
  File.write(CONTROLLER, body)
end

write_controller(verbs: %i[browse detail])

eager  = SCENARIO.start_with?("production")
declare = !SCENARIO.end_with?("undeclared") && SCENARIO != "production"

app = Class.new(Rails::Application) do
  config.root             = ROOT
  config.eager_load       = eager
  config.enable_reloading = !eager
  config.secret_key_base  = "handler-registration-probe"
  config.logger           = Logger.new(IO::NULL)
  config.hosts.clear
end
Object.const_set(:ProbeApp, app)

Kiosk.configure do |c|
  c.issuer      = "http://localhost"
  c.user_model  = "User"
  c.signing_key = Kiosk::Server::SigningKey.generate
  c.handlers    = %w[Kiosk::ProbeController] if declare
end

Rails.application.initialize!

def snapshot
  {
    "queries" => Kiosk::Server::Queries.known.sort,
    "actions" => Kiosk::Server::Actions.known.sort,
    "descriptions" => Kiosk::Server::Queries.catalog.to_h { |d| [d[:name], d[:description]] },
    "capabilities" => Kiosk.configuration.capabilities,
    "browse_fetches" => begin
      Kiosk::Server::Queries.fetch("probe_browse").class.name
    rescue Kiosk::Server::Errors::NotFound => e
      "NotFound: #{e.hint}"
    end,
    "added_fetches" => begin
      Kiosk::Server::Queries.fetch("probe_added").class.name
    rescue Kiosk::Server::Errors::NotFound => e
      "NotFound: #{e.hint}"
    end,
  }
end

report = { "boot" => snapshot }

if SCENARIO == "development"
  # A dev reload cycle, three times — exactly what Rails runs when a file
  # changed between requests. No restart, no re-boot.
  write_controller(verbs: %i[browse detail], browse_description: "EDITED without a restart.")
  Rails.application.reloader.reload!
  report["after_edit"] = snapshot

  write_controller(verbs: %i[browse detail added])
  Rails.application.reloader.reload!
  report["after_add"] = snapshot

  write_controller(verbs: %i[detail])
  Rails.application.reloader.reload!
  report["after_remove"] = snapshot
end

puts JSON.generate(report)
