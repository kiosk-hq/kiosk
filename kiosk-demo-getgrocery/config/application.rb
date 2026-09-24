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
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module KioskDemoGetgrocery
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # ── ACTIVE JOB: the `:async` adapter, in process ──────────────────────
    #
    # Zero tables and zero worker processes, against a durable queue's
    # thirteen. THE TRADE, STATED: an enqueued job is lost if this process
    # stops before it runs, so a deploy between a courier leaving and the
    # basket arriving leaves an order reading `out_for_delivery` for good.
    # That is acceptable HERE and would not be for the event stream itself,
    # and the difference is the one that matters: carrying a basket across
    # Dublin is this shop's DOMAIN work, not a step of the Kiosk wire. An
    # operator copying it copies «plan your own work however you like», which
    # is true. `config/cable.yml` takes the opposite choice for the opposite
    # reason.
    config.active_job.queue_adapter = :async

    # ── THE COURIER'S LEAD, as a published number ─────────────────────────
    #
    # Ten to fifteen minutes before the window opens, drawn once per order.
    # Configuration rather than a literal in the job because a suite has to be
    # able to pin it: a flow that waited a real twelve minutes for an
    # assertion is a flow nobody runs, and a gate nobody runs is a gate that
    # is not there. The shipped value is what a live viewer meets.
    #
    # There is deliberately no second number for the road. The courier arrives
    # as the window opens, and that instant is the window this shop already
    # published — see {OrderDeliveredJob}.
    config.x.getgrocery.courier_lead_seconds =
      ENV.fetch("GETGROCERY_COURIER_LEAD_SECONDS", rand(600..900).to_s).to_i

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # app/services holds the objects config/initializers/kiosk.rb HANDS to
    # `Kiosk.configure` at boot — the provider adapters and the demo stubs
    # behind them. Rails sets the RELOADABLE autoloader up in its
    # `finisher`, i.e. AFTER config/initializers have run, so a constant in a
    # normal autoload path is simply not resolvable from an initializer; that,
    # not "lib/ is not autoloaded", is what a hand-written
    # `require Rails.root.join("lib/...")` line buys.
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
