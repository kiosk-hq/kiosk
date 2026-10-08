require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"

Bundler.require(*Rails.groups)

module KioskDemoHoteling
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])

    # Initializers build objects from app/services, before the main autoloader is set up.
    config.autoload_once_paths << Rails.root.join("app/services").to_s

    config.active_job.queue_adapter = :async
    config.active_record.schema_format = :sql

    # The property's own decision: how often it declines, and how long it takes.
    config.x.hoteling.decline_rate           = ENV.fetch("HOTELING_DECLINE_RATE", "0.2").to_f
    config.x.hoteling.decision_delay_seconds =
      ENV.fetch("HOTELING_DECISION_DELAY_SECONDS", rand(120..300).to_s).to_i
  end
end
