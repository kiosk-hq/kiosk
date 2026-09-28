# frozen_string_literal: true

require "action_cable"

module Kiosk
  module Server
    # THE ENGINE'S OWN Action Cable server, and everything about where a stream
    # is named and how an event reaches it.
    #
    # == Why this is not `ActionCable.server`
    #
    # `ActionCable.server` is the host application's singleton: one connection
    # class, one forgery-protection setting for every channel the operator will
    # ever add. Taking it over would mean the engine deciding those for the host.
    #
    # `ActionCable::Server::Base.new(config:)` takes its OWN
    # {ActionCable::Server::Configuration}, carrying `connection_class`,
    # `cable` and the rest. So the engine mounts a server of its own, the
    # operator's stays untouched, and the request-forgery setting below reaches
    # the Kiosk stream and nothing else.
    #
    # == Stream naming
    #
    # One stream per (identity, topic): `kiosk:events:<user_id>:<topic>`.
    #
    # Per IDENTITY because delivery is per identity — the tail is, and a
    # subscriber must never be reachable through another principal's stream
    # name. Per TOPIC because a socket carries many subscriptions and each one
    # should only wake for its own. A SUBJECT is NOT in the name: subjects are
    # unbounded and operator-defined, so putting one in a stream name would let
    # a caller mint pubsub channels; the channel filters by subject after the
    # message arrives.
    module EventsCable
      STREAM_PREFIX = "kiosk:events"

      # Mounted in the engine's route table. A lambda rather than the server
      # object so the server is built on FIRST REQUEST rather than at
      # route-draw time, by which point the host application is fully loaded
      # and `cable_config` below can read its `config/cable.yml`.
      RACK_APP = ->(env) { Kiosk::Server::EventsCable.server.call(env) }

      class << self
        def server
          @server ||= ::ActionCable::Server::Base.new(config: configuration)
        end

        def stream_name(identity_key, topic)
          "#{STREAM_PREFIX}:#{identity_key}:#{topic}"
        end

        # Wake every socket subscribed to this identity's view of this topic.
        # Called by {Events.emit} AFTER the append, so the event already carries
        # the id a resuming client will compare against.
        def broadcast(identity_key, event)
          server.broadcast(stream_name(identity_key, event["topic"]), event)
        end

        def configuration
          @configuration ||= ::ActionCable::Server::Configuration.new.tap do |config|
            config.connection_class = -> { Kiosk::Server::EventsConnection }
            config.cable = cable_config
            config.logger = resolved_logger
            # `Origin` decides nothing on this stream, and Action Cable's
            # check of it is left off deliberately. That check defends a
            # BROWSER's ambient credentials; this upgrade is authorised by the
            # `Authorization` header (spec Section 8.5.3), which a page cannot
            # attach cross-origin, so the request has no ambient credential to
            # defend. Armed, it refuses every client that sends no `Origin` —
            # every non-browser stack there is — with a bare 404 on the URL
            # discovery advertises. This server is the engine's own, so the
            # setting reaches the Kiosk stream and no channel of the host's.
            config.disable_request_forgery_protection = true
          end
        end

        private

        # The host's own `config/cable.yml` if it has one, so an operator
        # configures pubsub in the one place Rails already taught them and the
        # engine adds no second setting.
        #
        # THE FALLBACK IS `async` AND IT IS NOT A DEFAULT WE CHOSE — it is the
        # one that is safe. Action Cable's own default when `cable.yml` is
        # absent is REDIS (`Server::Configuration#pubsub_adapter`,
        # `cable.fetch("adapter") { "redis" }`), which would raise a LoadError
        # at the first upgrade on every host in this fleet. `async` is correct
        # in one process and wrong in several, so a deployed operator writes a
        # `cable.yml` on a shared adapter; that is what `solid_cable` is for
        # and why the demos ship one.
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
