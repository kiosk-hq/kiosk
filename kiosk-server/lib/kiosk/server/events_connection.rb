# frozen_string_literal: true

require "action_cable"
require "json"
require "rack"

module Kiosk
  module Server
    # The Action Cable connection behind `<endpoint>/events`.
    #
    # == It reuses the HTTP chain byte for byte
    #
    # {IdentityResolution.resolve} is the same call every verb makes, and
    # `ActionCable::Connection::Request` answers `#headers` — which is all
    # `DefaultAgentIdp#authorization_for` is duck-typed on. So the upgrade gets
    # the RS256 signature check against the JWKS by `kid`, `aud` and `iss`
    # against the issuer, `exp`/`nbf`/`iat` with leeway, and the revocation
    # watermark, with NO new verification code and no second auth story.
    #
    # The token travels in the `Authorization` header of the upgrade request —
    # never the query string, which would put a bearer token in every access log
    # on the path.
    class EventsConnection < ::ActionCable::Connection::Base
      # The identifier is the user_id STRING and not the {Kiosk::Identity}
      # object. Action Cable renders every `identified_by` value into a
      # connection identifier (`to_gid_param` or `to_s`) and keys its remote
      # registry on it, so a rich object there is a serialisation problem
      # waiting for the first `disconnect`. The full identity hangs off the
      # connection as an ordinary reader for the channel to read.
      identified_by :kiosk_identity_key

      attr_reader :kiosk_identity

      # Action Cable beats every 3 seconds — `Server::Connections::BEAT_INTERVAL`,
      # a bare constant with no configuration accessor anywhere in 8.1.
      #
      # That cadence is invisible to a client that filters the envelope and
      # FATAL to one that does not. MEASURED 2026-09-25 against a harness whose
      # WebSocket source surfaces every frame to the agent: the pings alone
      # exhausted its notification budget and two real Kiosk messages were
      # suppressed before the agent ever saw them.
      #
      # Ten beats to one ping is 30 seconds — ten times any useful signal on
      # this stream, and well inside every idle timeout on the path. Throttling
      # HERE rather than patching the constant keeps it to this connection: a
      # host's own channels keep Rails' cadence.
      BEATS_PER_PING = 10

      def connect
        identity = resolve_identity || reject_unauthorized_connection
        @kiosk_identity = identity
        self.kiosk_identity_key = identity.user_id.to_s
      end

      # Subscriptions declared in the URL (spec Section 8.5.4). A receive-only
      # client cannot SEND, so it can
      # never issue Action Cable's `subscribe` command and would sit on an open
      # socket receiving nothing, forever. Everything such a client needs to
      # say, it therefore says in the URL:
      #
      #   wss://<origin>/kiosk/events?topic=todo:list_4f1e&topic=delivery&since=880
      #
      # These are SYNTHESISED into exactly the commands the client would have
      # sent, through Action Cable's own `subscriptions`, so there is ONE code
      # path underneath and not a second set of semantics: authorisation,
      # replay and the subscribed frame are the channel's, unchanged.
      def handle_open
        super
        auto_subscribe! if @kiosk_identity
      end

      def beat
        @beats = (@beats || 0) + 1
        super if (@beats % BEATS_PER_PING).zero?
      end

      private

      def auto_subscribe!
        requested_topics.each do |topic, subject|
          identifier = { "channel" => "KioskEvents", "topic" => topic }
          identifier["subject"] = subject if subject
          identifier["since"] = requested_since if requested_since
          subscriptions.execute_command(
            "command" => "subscribe", "identifier" => ::JSON.generate(identifier)
          )
        end
      end

      # `Rack::Utils.parse_query` rather than `request.query_parameters`
      # because a repeated key is the natural spelling for a repeated
      # subscription and Rack returns an ARRAY for one, where Rails' own
      # parsing keeps only the last. Both spellings work:
      #
      #   ?topic=todo&topic=delivery          — repeated
      #   ?topic=todo,delivery                — comma-separated
      #
      # A subject is appended after a colon (`todo:list_4f1e`), which is
      # unambiguous because spec Section 8.5.1 draws a topic name from the same
      # vocabulary as a verb name, which forbids a colon.
      def requested_topics
        raw = ::Rack::Utils.parse_query(request.query_string)["topic"]
        Array(raw).flat_map { |value| value.to_s.split(",") }
                  .map(&:strip).reject(&:empty?)
                  .map { |value| value.split(":", 2) }
                  .map { |topic, subject| [topic, (subject unless subject.to_s.empty?)] }
      end

      def requested_since
        value = ::Rack::Utils.parse_query(request.query_string)["since"]
        value = value.last if value.is_a?(Array)
        return nil if value.nil? || value.to_s.empty?

        value.to_i
      end

      # An adapter returns nil for a credential it does not recognise; it does
      # not raise. A raise here would be a bug in an operator's own IdP, and the
      # right answer to it is still a refused upgrade rather than a 500 on a
      # socket nobody can read.
      def resolve_identity
        Kiosk::Server::IdentityResolution.resolve(request)
      rescue StandardError => e
        logger.error("[kiosk] events connection identity resolution failed: #{e.class}") if logger
        nil
      end
    end
  end
end
