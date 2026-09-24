# frozen_string_literal: true

require "action_cable"

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

      def beat
        @beats = (@beats || 0) + 1
        super if (@beats % BEATS_PER_PING).zero?
      end

      private

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
