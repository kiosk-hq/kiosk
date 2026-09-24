# frozen_string_literal: true

require "kiosk/server/jwt_issuer"
require "kiosk/server/jwks"

module Kiosk
  module Server
    # A SINGLE-USE CONNECT TICKET for the event stream (spec Section 8.5.3).
    #
    # == Why it exists at all
    #
    # The wire puts the bearer token in the `Authorization` header of the upgrade,
    # on a reason that still stands: a query-string token lands in every access
    # log on the path. The consequence, invisible while a long-poll fallback
    # existed, is that a harness with a perfectly good BUILT-IN WebSocket client
    # cannot use the stream at all — those clients routinely take a URL and a
    # subprotocol list and nothing else. MEASURED 2026-09-25 on the very
    # runtime this design was verified against: its native WebSocket source
    # accepts `{url, protocols}` and has no way to send a header.
    #
    # So the socket accepts EITHER the header OR `?ticket=…`, and the header
    # stays the recommended path.
    #
    # == Why a ticket in a log is not a token in a log
    #
    # Three properties, and it needs all three:
    #
    #   * a 30-SECOND lifetime, so a copy is stale about as fast as it is written;
    #   * a DISTINCT audience — `<endpoint>/events` — so a ticket cannot be
    #     presented as an access token to any verb, and an access token cannot be
    #     presented as a ticket;
    #   * SINGLE USE, claimed below, so a replay of a still-fresh copy loses.
    #
    # == The single-use claim reuses the spent store, deliberately
    #
    # {PowSpentStores} is already «claim this opaque id as spent until this
    # expiry», which is exactly what a ticket `jti` needs, and an operator above
    # one worker has ALREADY had to configure a shared one — the initializer
    # spells out why. Adding a fourth store seam for the same operation would
    # give that operator a second thing to get right and this codebase a second
    # idiom for one job.
    #
    # The ticket itself is STATELESS — a short RS256 JWT verified by the same
    # JWKS as everything else — so minting needs no shared state at all. Only
    # the spend does, and a multi-process operator who has not configured the
    # store gets the failure LOUDLY: the second use of a ticket is refused, not
    # silently accepted.
    module EventsTicket
      TTL_SECONDS = 30

      module_function

      # `<issuer><mount>/events`. Distinct from the access-token audience
      # (`config.issuer`), which is what keeps the two kinds of credential from
      # standing in for each other.
      def audience
        issuer = Kiosk.configuration.issuer.to_s.chomp("/")
        "#{issuer}#{Kiosk.configuration.mount_path}/events"
      end

      # @param identity [Kiosk::Identity] the caller the ticket speaks for
      # @return [String] compact JWS
      def mint(identity)
        JwtIssuer.issue(
          claims: {
            sub: identity.user_id.to_s,
            agent_id: identity.agent_id,
            role: identity.role,
            actor: identity.actor,
          },
          audience: audience,
          expires_in: TTL_SECONDS,
        )
      end

      # @return [Kiosk::Identity, nil] nil for anything that does not verify,
      #   has the wrong audience, has expired, or has already been spent — the
      #   caller turns all four into one refused upgrade, because telling a
      #   client WHICH of them it was would be telling an attacker the same.
      def redeem(token)
        return nil if token.nil? || token.to_s.empty?

        claims = JwtIssuer.verify(
          token: token.to_s,
          jwks: Jwks.build(keys: [Kiosk.configuration.signing_key]),
          audience: audience,
          issuer: Kiosk.configuration.issuer,
        )
        return nil unless spend(claims[:jti], claims[:exp])

        Kiosk::Identity.new(
          user_id: claims[:sub],
          role: claims[:role],
          actor: claims[:actor],
          agent_id: claims[:agent_id],
        )
      rescue StandardError
        nil
      end

      def spend(jti, exp)
        return false if jti.nil?

        Kiosk.configuration.pow_spent_store.claim(jti.to_s, exp.to_i)
      end
    end
  end
end
