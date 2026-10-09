require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"

Bundler.require(*Rails.groups)

module KioskDemoAtablefor
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])

    # public first: the kiosk tables reference public.users.
    config.active_record.dump_schemas = "public,kiosk"

    # The proof-of-work every registration and tolled query pays.
    config.x.equihash = { n: 168, k: 7 }
  end
end
