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
# Usage: ruby handler_registration_probe_app.rb development|production
# development also runs three reloads: an edited, an added and a removed verb.

require "bundler/setup"
require "fileutils"
require "json"
require "tmpdir"
require "active_job/railtie"
require "kiosk/server"

SCENARIO = ARGV.fetch(0)
ROOT     = Dir.mktmpdir("kiosk-handler-probe")
at_exit { FileUtils.remove_entry(ROOT) if File.directory?(ROOT) }

CONTROLLER = File.join(ROOT, "app/controllers/kiosk/probe_controller.rb")
FileUtils.mkdir_p(File.dirname(CONTROLLER))

SCHEMAS =
  %(  kind :query\n) +
  %(  input_schema type: "object", additionalProperties: false, properties: {}, required: []\n) +
  %(  output_schema type: "array", items: { type: "object" }\n)

# Generation 1 of the operator's handler controller: two verbs.
def write_controller(verbs:, browse_description: "Generation 1 description.")
  body = +"class Kiosk::ProbeController < ActionController::Base\n  include Kiosk::Handler\n"
  if verbs.include?(:browse)
    body << "\n  description #{browse_description.inspect}\n#{SCHEMAS}  def probe_browse\n    render json: []\n  end\n"
  end
  if verbs.include?(:detail)
    body << "\n  description \"The second verb.\"\n#{SCHEMAS}  def probe_detail\n    render json: []\n  end\n"
  end
  if verbs.include?(:added)
    body << "\n  description \"Added while the app was running.\"\n#{SCHEMAS}  def probe_added\n    render json: []\n  end\n"
  end
  body << "end\n"
  File.write(CONTROLLER, body)
end

write_controller(verbs: %i[browse detail])

eager = SCENARIO == "production"

app = Class.new(Rails::Application) do
  config.root             = ROOT
  config.eager_load       = eager
  config.paths["config"] << File.expand_path("config", __dir__)
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
end

Rails.application.initialize!

# Read before anything asks for the digest, so it shows the boot derived it.
DERIVED_AT_BOOT = Kiosk::Server::SchemaDocument.derived?

def snapshot
  {
    "schema_digest" => Kiosk::Server::SchemaDocument.digest,
    "queries" => Kiosk::Server::Queries.known.sort,
    "actions" => Kiosk::Server::Actions.known.sort,
    "descriptions" => Kiosk::Server::Queries.catalog.to_h { |d| [d[:name], d[:description]] },
    "capabilities" => Kiosk.configuration.capabilities,
    "browse_fetches" => begin
      Kiosk::Server::Queries.fetch("probe_browse").class.name
    rescue Kiosk::Server::Errors::VerbNotFound => e
      "NotFound: #{e.hint}"
    end,
    "added_fetches" => begin
      Kiosk::Server::Queries.fetch("probe_added").class.name
    rescue Kiosk::Server::Errors::VerbNotFound => e
      "NotFound: #{e.hint}"
    end,
  }
end

report = { "boot" => snapshot.merge("derived_at_boot" => DERIVED_AT_BOOT) }

if SCENARIO == "development"
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
