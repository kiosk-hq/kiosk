# frozen_string_literal: true

require 'action_cable'
require 'json'
require 'rack'

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
      CHANNEL = 'KioskEvents'

      # A subscriber never publishes (spec Section 8.5.5), so no `message`.
      COMMANDS = %w[subscribe unsubscribe].freeze

      # §8.5.6: the credential is re-checked at least every 60 seconds, on every socket.
      class_attribute :reauthorise_every, default: 30

      # The `subscribe` identifiers that the upgrade URL's `topic` and `since` declare.
      module UrlSubscriptions
        module_function

        def identifiers(query_string)
          query = ::Rack::Utils.parse_query(query_string)
          since = since(query['since'])
          topics(query['topic']).map do |topic, subject|
            identifier = { 'channel' => CHANNEL, 'topic' => topic }
            identifier['subject'] = subject if subject
            identifier['since'] = since if since
            ::JSON.generate(identifier)
          end
        end

        # `?topic=todo&topic=delivery` or `?topic=todo,delivery`, a subject after
        # a colon (a topic name cannot hold one). `Rack::Utils.parse_query`
        # because Rails keeps only the last of a repeated key.
        def topics(raw)
          Array(raw).flat_map { |value| value.to_s.split(',') }
                    .map(&:strip).reject(&:empty?)
                    .map { |value| value.split(':', 2) }
                    .map { |topic, subject| [topic, (subject unless subject.to_s.empty?)] }
        end

        # Digits become an Integer; anything else passes through for
        # {KioskEvents} to refuse.
        def since(value)
          value = value.last if value.is_a?(Array)
          return nil if value.blank?

          value.match?(/\A\d+\z/) ? value.to_i : value
        end
      end

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
        command = frame['command']
        identifier = frame['identifier']

        return close_invalid_request unless COMMANDS.include?(command) && identifier.is_a?(::String)

        live = subscriptions.identifiers.include?(identifier)
        return transmit_about(identifier, :confirmation) if command == 'subscribe' && live
        return transmit_about(identifier, :rejection) unless actionable?(command, identifier, live)

        super
      end

      # Closes with `token_expired` or `revoked` once the credential no longer resolves (§8.5.6).
      def kiosk_credential_holds?
        return true if token_holds?

        if kiosk_credential_expired?
          close(reason: 'token_expired', reconnect: true)
        else
          close(reason: 'revoked', reconnect: false)
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

      def close_invalid_request
        close(reason: ::ActionCable::INTERNAL[:disconnect_reasons][:invalid_request], reconnect: false)
      end

      def transmit_about(identifier, type)
        transmit(identifier: identifier, type: ::ActionCable::INTERNAL[:message_types][type])
      end

      # An `unsubscribe` must name a live subscription by its exact string; a
      # `subscribe` must name this channel, and {KioskEvents} judges the rest.
      def actionable?(command, identifier, live)
        return live if command == 'unsubscribe'

        parse_object(identifier)&.dig('channel') == CHANNEL
      end

      def auto_subscribe!
        UrlSubscriptions.identifiers(request.query_string).each do |identifier|
          subscriptions.execute_command('command' => 'subscribe', 'identifier' => identifier)
        end
      end

      # The token and the DPoP proof of the upgrade request.
      def resolve_identity
        under_issuer { Kiosk::Server::IdentityResolution.resolve(request) }
      end

      # §8.5.6: the proof was checked once, at the upgrade, and is past its
      # 60-second window by now; a re-check reads the token alone.
      def token_holds?
        under_issuer { Kiosk::Server::IdentityResolution.agent_idp.verify(request) }
      end

      # Under the upgrade's own issuer: this runs outside {IssuerMiddleware}.
      # A raising IdP refuses the upgrade rather than failing the socket.
      def under_issuer(&)
        Kiosk.with_issuer(Kiosk.configuration.issuer_for(request.base_url), &)
      rescue StandardError => e
        logger&.error("[kiosk] events connection identity resolution failed: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
