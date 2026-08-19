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

      # ── THE WRITTEN EXCEPTION to the policy above (T-094, K-804) ─────────
      #
      # `GET <endpoint>/schema` is PUBLIC since T-094, and
      # `GET <endpoint>/openapi.json` joined it at K-804: both carry verb
      # names, descriptions and schemas, nothing per-agent and no secret, and
      # both are rendered from in-process state. So the two rules the default
      # encodes stop applying to them, and both must be actively UNDONE rather
      # than merely relaxed:
      #
      #   * `private, no-store` becomes `public, max-age=…`. A shared cache is
      #     the point — an origin that answers every assistant with the same
      #     bytes should answer most of them from a CDN edge.
      #   * `Vary: Authorization, Kiosk-PoW` is NOT emitted. This is the half
      #     that would silently undo the other: a public document that varies
      #     on a header it no longer reads is, to a shared cache, a different
      #     document per caller — cacheable in theory and never hit in
      #     practice. The endpoint reads neither header, so naming them would
      #     also be a lie.
      #
      # TWO TTLs, because a fixed URL cannot safely carry a long one. Ask for
      # `/kiosk/schema` and you get {SHORT_MAX_AGE}: the path never changes, so
      # anything longer means a CDN serving a catalogue from before the last
      # deploy, invisibly, to an assistant that then calls verbs which no
      # longer exist. Ask for `/kiosk/schema?v=<digest>` — the URL the
      # discovery documents link, digest from {SchemaDocument} — and you get
      # {IMMUTABLE_MAX_AGE}, because that URL's answer cannot change: a deploy
      # that changes the catalogue changes the digest, the discovery documents
      # (short TTL) publish the new link, and nothing is pointed at the old one
      # any more. It is the asset-pipeline pattern, and it is what makes a
      # year safe rather than a bug.
      #
      # WHY THE SHORT ONE IS SIXTY SECONDS AND NOT FIVE MINUTES (Phil,
      # 2026-08-19). The number is not a cache-efficiency knob; it is the
      # length of time an operator has to live with AFTER A DEPLOY, during
      # which some callers still hold the previous pointer document and follow
      # the previous `?v=` link. Phil weighed exactly that: «это после деплоя
      # придётся … мириться с тем, что все будут получать старый документ. На
      # другой стороне весов — чтобы не слишком часто дёргался backend.
      # Кажется, max-age в 1m будет сносным компромиссом.» A minute of
      # post-deploy staleness is tolerable; five was chosen when nobody had
      # asked that question. The load side of the trade is NOT paid by this
      # number — it is paid by {IMMUTABLE_MAX_AGE} on the versioned URL, which
      # is where the bytes actually are, because an assistant follows the link
      # from the pointer rather than re-fetching the catalogue itself.
      SHORT_MAX_AGE     = 60          # one minute — the fixed, unversioned URL
      IMMUTABLE_MAX_AGE = 31_536_000  # a year — a digest-versioned URL

      # Written in Rails' own directive order (`max-age` first, then the
      # cacheability, then the extras) because ActionDispatch REGENERATES this
      # header on commit from its parsed form — writing "public, max-age=60"
      # here produces "max-age=60, public" on the wire. Spelling it the way it
      # is emitted keeps a grep of this file and a grep of a response agreeing.
      PUBLIC_SHORT     = "max-age=#{SHORT_MAX_AGE}, public"
      PUBLIC_IMMUTABLE = "max-age=#{IMMUTABLE_MAX_AGE}, public, immutable"

      # Apply the public policy to ONE response.
      #
      # IT SETS NO `Vary`, AND THAT IS THE POINT — Phil, 2026-08-19, on the
      # discovery documents: «А Vary зачем? Это паблик, общедоступная инфа.»
      # `Vary` belongs on the per-identity plane, where the answer really does
      # depend on `Authorization` and `Kiosk-PoW`, and those answers are
      # `private, no-store` anyway. A public document has one answer for
      # everyone; naming a header it does not read would state a variance that
      # does not exist. Note this method cannot DELETE what Rails adds after
      # it — `_set_vary_header` stamps `Vary: Accept` at render time — so a
      # public action must drop the header itself, AFTER the render.
      #
      # @param headers   [Hash] the response headers to mutate
      # @param etag      [String] the STRONG entity tag, already quoted
      # @param immutable [Boolean] true when the URL carries the matching digest
      def self.add_public_cache_policy(headers, etag:, immutable:)
        headers["Cache-Control"] = immutable ? PUBLIC_IMMUTABLE : PUBLIC_SHORT
        headers["ETag"] = etag
        headers
      end
    end
  end
end
