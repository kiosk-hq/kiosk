# frozen_string_literal: true

require "kiosk/server/actions"
require "kiosk/server/errors"
require "kiosk/server/kyc"
require "kiosk/server/payment_setup"
require "kiosk/server/queries"

module Kiosk
  module Server
    # Rebuilds the verb and topic registries from every class that includes
    # Kiosk::Handler. The engine calls {reload!} from `to_prepare`, so a verb
    # added, edited or removed in development is served after the next reload.
    module HandlerRegistrations
      HANDLERS_DIR = "app/controllers/kiosk"

      class << self
        def add(handler)
          handlers << handler.name if handler.name
        end

        def reload!
          clear!
          load_handlers_dir
          handlers.select! { |name| name.safe_constantize&.kiosk_register! }
          PaymentSetup.register! if Kiosk.configuration.payment_provider
          Kyc.register! if Kiosk.configuration.kyc_provider
          refuse_cross_kind_collisions!
        end

        def clear!
          [Actions, Queries, Events].each do |registry|
            registry.known.each { |name| registry.unregister(name) }
          end
        end

        def handlers
          @handlers ||= Set.new
        end

        private

        def load_handlers_dir
          return unless defined?(::Rails) && ::Rails.application

          dir = ::Rails.root.join(HANDLERS_DIR)
          ::Rails.autoloaders.main.eager_load_dir(dir) if dir.directory?
        end

        def refuse_cross_kind_collisions!
          both = Actions.known & Queries.known
          return if both.empty?

          raise Errors::ConfigurationError,
            "#{both.sort.join(", ")} #{both.one? ? "is" : "are"} declared as BOTH a query and " \
            "an action. GET #{Kiosk.configuration.mount_path}/<name> is a query and " \
            "POST #{Kiosk.configuration.mount_path}/<name> is an action, so one name cannot be " \
            "both. Rename one of them, or give it a `wire_name` of its own."
        end
      end
    end
  end
end
