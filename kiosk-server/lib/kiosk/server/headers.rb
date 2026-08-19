# frozen_string_literal: true

module Kiosk
  module Server
    # Helper for composing the three response headers kiosk-server sends on
    # every `/kiosk/*` response (the API-version handshake).
    module Headers
      # Mutate a Rack headers hash to add the three Kiosk headers.
      # The server version defaults to {Kiosk::Server::VERSION}; callers
      # may override (e.g. tests).
      def self.add_to(headers, server_version: Kiosk::Server::VERSION)
        headers[Kiosk::Protocol::HEADER_SERVER_VERSION] = server_version
        headers[Kiosk::Protocol::HEADER_API_VERSION]    = Kiosk::Protocol::API_VERSION
        headers[Kiosk::Protocol::HEADER_MIN_CLIENT]     = Kiosk::Protocol::MIN_CLIENT
        headers
      end

      # Build a fresh headers hash with the three Kiosk headers set.
      def self.build(server_version: Kiosk::Server::VERSION)
        add_to({}, server_version: server_version)
      end

      # The `Vary` a wire response MUST carry (design §3.3 rule 1, T-068
      # slice 2). Two request headers change the answer and neither is in the
      # URL: `Authorization` (every wire response is identity-scoped) and
      # `Kiosk-PoW` (a tolled 200 and its 402 differ ONLY by this header).
      # Without the second, a private cache keyed on the URL serves a paid 200
      # to an unpaid retry — defeating the toll — or a stale 402 to a paid
      # one, which is an infinite retry loop.
      WIRE_VARY = %w[Authorization Kiosk-PoW].freeze

      # Cache policy for ONE wire response. Applied at the render seam, not in
      # {HeadersMiddleware}: the middleware covers every path under the mount,
      # including `/kiosk/.well-known/jwks.json`, whose whole point is that it
      # is public, long-lived and cacheable. A `Vary: Authorization` there
      # would be a lie and a performance regression.
      #
      #   * `Vary` — the wire tokens are ADDED to whatever the operator
      #     already set, never replacing it.
      #   * `Cache-Control` on a 402 — forced to `no-store`. A PoW challenge
      #     is single-use, request-bound and expiring; caching one is actively
      #     harmful, so this is the one directive an operator cannot relax.
      #   * `Cache-Control` otherwise — defaults to `private, no-store`, and
      #     an operator who has already set one keeps it. That is what lets a
      #     genuinely identity-independent payload be served
      #     `private, max-age=N`, which is also how an assistant's own cache
      #     saves a toll: a fresh cached response is never re-requested and
      #     therefore never re-challenged.
      #
      # @param headers [Hash] the response headers to mutate
      # @param status  [Integer] the HTTP status being rendered
      def self.add_cache_policy(headers, status:)
        present = headers["Vary"].to_s.split(",").map { |t| t.strip }.reject(&:empty?)
        missing = WIRE_VARY.reject { |t| present.any? { |p| p.casecmp?(t) } }
        headers["Vary"] = (present + missing).join(", ")

        if status.to_i == 402
          headers["Cache-Control"] = "no-store"
        elsif headers["Cache-Control"].to_s.empty?
          headers["Cache-Control"] = "private, no-store"
        end
        headers
      end
    end
  end
end
