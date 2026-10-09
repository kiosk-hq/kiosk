# frozen_string_literal: true

require "action_cable"
require "json"
require "kiosk/server/errors"
require "kiosk/server/headers"
require "rack"

module Kiosk
  module Server
    # The engine's own Action Cable server, so the host's connection class and forgery setting stay
    # the host's. One stream per (identity, topic); the channel filters by subject.
    module EventsCable
      STREAM_PREFIX = "kiosk:events"

      # A lambda, so the server is built on first request, once the host's
      # `config/cable.yml` can be read.
      RACK_APP = ->(env) { Kiosk::Server::EventsCable.serve(env) }

      UNSERVED_DETAIL = "this operator does not serve the events module"
      UNSERVED_HINT   = "`events` is absent from this origin's capabilities and it publishes no " \
                        "events_url; there is nothing to subscribe to here"

      class << self
        # An origin that declares no topic answers `501 module_not_served`
        # (spec Sections 8.5.3, 16.1 item 9), before any credential is read.
        def serve(env)
          return unserved_module if Kiosk::Server::Events.known.empty?

          server.call(env)
        end

        def server
          @server ||= ::ActionCable::Server::Base.new(config: configuration)
        end

        def stream_name(identity_key, topic)
          "#{STREAM_PREFIX}:#{identity_key}:#{topic}"
        end

        # Called by {Events.emit} after the append, so the event carries its id.
        def broadcast(identity_key, event)
          server.broadcast(stream_name(identity_key, event["topic"]), event)
        end

        def configuration
          @configuration ||= ::ActionCable::Server::Configuration.new.tap do |config|
            config.connection_class = -> { Kiosk::Server::EventsConnection }
            config.cable = cable_config
            config.logger = resolved_logger
            # Authorised by the `Authorization` header, which a page cannot attach cross-origin.
            config.disable_request_forgery_protection = true
          end
        end

        private

        def unserved_module
          error   = Errors::ModuleNotServed.new(UNSERVED_DETAIL, hint: UNSERVED_HINT)
          headers = ::Rack::Headers.new
          headers["content-type"] = Errors::PROBLEM_CONTENT_TYPE
          Headers.add_to(headers)
          Headers.add_cache_policy(headers, status: error.http_status)
          [error.http_status, headers, [::JSON.generate(error.to_problem)]]
        end

        # The host's `config/cable.yml`, else `async` (one process only):
        # Action Cable's own fallback is Redis, which no host here bundles.
        def cable_config
          return { "adapter" => "async" } unless rails_app_with_cable_yml?

          ::Rails.application.config_for(:cable).to_h.transform_keys(&:to_s)
        rescue StandardError
          { "adapter" => "async" }
        end

        def rails_app_with_cable_yml?
          defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application &&
            ::Rails.root && ::File.exist?(::Rails.root.join("config", "cable.yml"))
        end

        def resolved_logger
          return ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

          ::Logger.new(IO::NULL)
        end
      end
    end
  end
end
