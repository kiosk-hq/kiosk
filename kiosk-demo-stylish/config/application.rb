require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
# active_job/railtie is NOT loaded: no demo in the fleet defines a job or
# enqueues one, and the frameworks this app does not use stay unloaded the same
# way active_storage/action_mailer/action_mailbox/action_text/action_cable do
# below. Re-add the require in the same commit that adds the first job class.
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module KioskDemoStylish
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # No `config.autoload_once_paths`: nothing under app/ is named during
    # initialization. config/initializers/kiosk.rb reaches the difficulty knob
    # through the kiosk-pow-equihash gem, which Bundler has already loaded, and
    # everything else this app defines is reached from controllers and routes —
    # both of which run after Rails has set the reloadable autoloader up.

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Full middleware stack (NOT api_only): the account-binding ceremony
    # runs on real browser sessions — the human signs in through the
    # Devise form and the verify/link/unlink surfaces read that session
    # cookie — so cookies, session and flash middleware must be present.
    # The agent-facing wire controllers stay ActionController::API inside
    # kiosk-server and are unaffected.
    config.api_only = false

    # Use SQL structure dump so pg_dump captures all schemas (kiosk.*, public.*).
    # schema.rb only introspects the public schema and silently drops the kiosk
    # schema tables, causing db:migrate on a fresh DB to skip those migrations.
    config.active_record.schema_format = :sql
  end
end
