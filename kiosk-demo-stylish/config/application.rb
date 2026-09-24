require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
# active_job/railtie IS loaded, and the trigger was the sentence this comment
# used to end with: «re-add the require in the same commit that adds the first
# job class». Nothing here named a job class — the GEM did. `solid_cable` ships
# `app/jobs/solid_cable/trim_job.rb` (`class TrimJob < ActiveJob::Base`) and its
# engine puts that directory on the eager-load path, so the constant is resolved
# at boot wherever `config.eager_load` is true.
#
# WHICH IS PRODUCTION AND NOT DEVELOPMENT, and that asymmetry is the whole
# reason this is written out rather than just fixed: development does not eager
# load, so every task, spec and local boot stayed green while `bin/rails
# runner 'Rails.application.eager_load!'` raised `uninitialized constant
# SolidCable::ActiveJob` and a production boot died. Caught by demo:isolation,
# whose probe eager-loads on purpose.
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# Action Cable IS loaded: the Kiosk engine mounts an event stream under the
# wire's endpoint, so this framework is one the app genuinely uses.
require "action_cable/engine"
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
