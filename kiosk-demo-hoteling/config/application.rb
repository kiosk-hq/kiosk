# frozen_string_literal: true

require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_job/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'
require 'action_cable/engine'

Bundler.require(*Rails.groups)

module KioskDemoHoteling
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])

    # Initializers build objects from app/services, before the main autoloader is set up.
    config.autoload_once_paths << Rails.root.join('app/services').to_s

    # Jobs wait in the database and run beside Puma (config/puma.rb); a finished one is deleted.
    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.preserve_finished_jobs = false

    # The property's own decision: how often it declines, and how long it takes.
    config.x.hoteling.decline_rate           = 0.2
    config.x.hoteling.decision_delay_seconds = 180
  end
end
