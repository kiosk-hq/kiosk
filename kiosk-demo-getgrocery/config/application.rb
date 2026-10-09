require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module KioskDemoGetgrocery
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])

    # Initializers build objects from app/services, before the main autoloader is set up.
    config.autoload_once_paths << Rails.root.join("app/services").to_s

    config.active_job.queue_adapter = :async
    # public first: the kiosk tables reference public.users.
    config.active_record.dump_schemas = "public,kiosk"
  end
end
