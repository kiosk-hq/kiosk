require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
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

module KioskDemoTudu
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # app/services holds the objects config/initializers/kiosk.rb HANDS to
    # `Kiosk.configure` at boot — the IdP adapters, the PoW-difficulty policy,
    # the telemetry middleware. Rails sets the RELOADABLE autoloader up in its
    # `finisher`, i.e. AFTER config/initializers have run, so a constant in a
    # normal autoload path is simply not resolvable from an initializer; that,
    # not "lib/ is not autoloaded", is what the hand-written
    # `require Rails.root.join("lib/...")` lines used to buy (K-502).
    # `autoload_once_paths` is Rails' own answer: the once autoloader is set up
    # in `bootstrap`, BEFORE initializers, "so that engines and applications
    # are able to autoload from these paths during initialization". It also
    # makes these classes non-reloadable, which is the honest posture for
    # objects an initializer instantiates once — a reload would swap the class
    # out from under the instance Kiosk.configuration is already holding.
    # Request-time code (domain modules, the wire operations) stays reloadable
    # under app/models, app/operations and app/controllers.
    config.autoload_once_paths << Rails.root.join("app/services").to_s

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Full middleware stack (NOT api_only): tudu keeps the full human web UI —
    # the tutorial-plain scaffold (lists, todos, invite, the manage-assistants
    # page) is the video centerpiece — and the account-binding ceremony runs on
    # real browser sessions (the human signs in through the Devise form and the
    # verify/link/unlink surfaces read that session cookie), so cookies, session
    # and flash middleware must be present. The agent-facing wire controllers
    # stay ActionController::API inside kiosk-server and are unaffected.
    config.api_only = false

    # Use SQL structure dump so pg_dump captures all schemas (kiosk.*, public.*).
    # schema.rb only introspects the public schema and silently drops the kiosk
    # schema tables, causing db:migrate on a fresh DB to skip those migrations.
    config.active_record.schema_format = :sql
  end
end
