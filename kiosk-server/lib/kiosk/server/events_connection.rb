# frozen_string_literal: true

require "action_cable"
require "json"
require "rack"

module Kiosk
  module Server
    # The Action Cable connection behind `<endpoint>/events`, authenticated from the
    # `Authorization` header, never the query string, which access logs record.
    class EventsConnection < ::ActionCable::Connection::Base
      # A String: Action Cable serialises every `identified_by` value.
      identified_by :kiosk_identity_key

      attr_reader :kiosk_identity

      # Action Cable beats every 3 seconds; forwarding one in ten keeps a client from drowning in them.
      BEATS_PER_PING = 10

      # The one channel a frame here may name; see {KioskEvents}.
      CHANNEL = "KioskEvents"

      # A subscriber never publishes (spec Section 8.5.5), so no `message`.
      COMMANDS = %w[subscribe unsubscribe].freeze

      # §8.5.6: the credential is re-checked at least every 60 seconds, on every socket.
      class_attribute :reauthorise_every, default: 30

      def connect
        identity = resolve_identity || reject_unauthorized_connection
        @kiosk_identity = identity
        self.kiosk_identity_key = identity.user_id.to_s
      end

      # Subscriptions declared in the URL (§8.5.4) become `subscribe` commands.
      def handle_open
        super
        return unless @kiosk_identity

        @reauthorisation = server.event_loop.timer(reauthorise_every) { send_async(:reauthorise!) }
        auto_subscribe!
      end

      def handle_close
        @reauthorisation&.shutdown
        super
      end

      def beat
        @beats = (@beats || 0) + 1
        super if (@beats % BEATS_PER_PING).zero?
      end

      # Every frame is answered (§8.5.4, §8.5.7); a repeated `subscribe` is confirmed again, not replayed.
      def dispatch_websocket_message(websocket_message)
        frame = parse_object(websocket_message) || {}
        command = frame["command"]
        identifier = frame["identifier"]

        unless COMMANDS.include?(command) && identifier.is_a?(::String)
          return close(reason: ::ActionCable::INTERNAL[:disconnect_reasons][:invalid_request],
                       reconnect: false)
        end

        live = subscriptions.identifiers.include?(identifier)
        return transmit_about(identifier, :confirmation) if command == "subscribe" && live
        return transmit_about(identifier, :rejection) unless actionable?(command, identifier, live)

        super
      end

      # Closes with `token_expired` or `revoked` once the credential no longer resolves (§8.5.6).
      def kiosk_credential_holds?
        return true if resolve_identity

        if kiosk_credential_expired?
          close(reason: "token_expired", reconnect: true)
        else
          close(reason: "revoked", reconnect: false)
        end
        false
      end

      private

      def reauthorise!
        kiosk_credential_holds?
      rescue StandardError => e
        logger.error("[kiosk] events re-authorisation failed: #{e.class}: #{e.message}")
      end

      def kiosk_credential_expired?
        exp = kiosk_identity.claims&.dig(:exp)
        !exp.nil? && Time.now.to_i >= exp.to_i
      end

      # Nil for anything that is not a JSON object.
      def parse_object(document)
        parsed = ::JSON.parse(document)
        parsed if parsed.is_a?(::Hash)
      rescue ::JSON::ParserError
        nil
      end

      def transmit_about(identifier, type)
        transmit(identifier: identifier, type: ::ActionCable::INTERNAL[:message_types][type])
      end

      # An `unsubscribe` must name a live subscription by its exact string; a
      # `subscribe` must name this channel, and {KioskEvents} judges the rest.
      def actionable?(command, identifier, live)
        return live if command == "unsubscribe"

        parse_object(identifier)&.dig("channel") == CHANNEL
      end

      def auto_subscribe!
        since = requested_since
        requested_topics.each do |topic, subject|
          identifier = { "channel" => CHANNEL, "topic" => topic }
          identifier["subject"] = subject if subject
          identifier["since"] = since if since
          subscriptions.execute_command(
            "command" => "subscribe", "identifier" => ::JSON.generate(identifier)
          )
        end
      end

      # `?topic=todo&topic=delivery` or `?topic=todo,delivery`, a subject after
      # a colon (a topic name cannot hold one). `Rack::Utils.parse_query`
      # because Rails keeps only the last of a repeated key.
      def requested_topics
        raw = ::Rack::Utils.parse_query(request.query_string)["topic"]
        Array(raw).flat_map { |value| value.to_s.split(",") }
                  .map(&:strip).reject(&:empty?)
                  .map { |value| value.split(":", 2) }
                  .map { |topic, subject| [topic, (subject unless subject.to_s.empty?)] }
      end

      # Digits become an Integer; anything else passes through for
      # {KioskEvents} to refuse.
      def requested_since
        value = ::Rack::Utils.parse_query(request.query_string)["since"]
        value = value.last if value.is_a?(Array)
        return nil if value.nil? || value.empty?

        value.match?(/\A\d+\z/) ? value.to_i : value
      end

      # Under the upgrade's own issuer: this runs outside {IssuerMiddleware}.
      # A raising IdP refuses the upgrade rather than failing the socket.
      def resolve_identity
        issuer = Kiosk.configuration.issuer_for(request.base_url)
        Kiosk.with_issuer(issuer) { Kiosk::Server::IdentityResolution.resolve(request) }
      rescue StandardError => e
        logger.error("[kiosk] events connection identity resolution failed: #{e.class}") if logger
        nil
      end
    end
  end
end
