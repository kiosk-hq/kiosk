# frozen_string_literal: true

module Kiosk
  module Server
    # Helper for composing the three response headers kiosk-server sends on
    # every `/kiosk/*` response (the API-version handshake).
    module Headers
      # Mutate a Rack headers hash to add the three Kiosk headers.
      # The server version defaults to {Kiosk::Server::VERSION}; callers
      # may override (e.g. tests).
      #
      # `Kiosk-Min-Client` is read from `Kiosk.configuration.min_client`, NOT
      # from the {Kiosk::Protocol::MIN_CLIENT} constant, so both surfaces that
      # publish this advisory number publish the SAME number: the header here
      # and `kiosk.min_client` in `/.well-known/kiosk.json` ({WellKnown}),
      # which reads the settable value. Emitting the constant here would mean
      # an operator who set `c.min_client = "0.5.0"` got a discovery document
      # saying 0.5.0 and every wire response saying 0.4.0, with nothing to tell
      # a client which was authoritative — a knob that worked on one of the two
      # places it is read. The constant is still the DEFAULT: it is what the
      # setter falls back to.
      def self.add_to(headers, server_version: Kiosk::Server::VERSION)
        headers[Kiosk::Protocol::HEADER_SERVER_VERSION] = server_version
        headers[Kiosk::Protocol::HEADER_API_VERSION]    = Kiosk::Protocol::API_VERSION
        headers[Kiosk::Protocol::HEADER_MIN_CLIENT]     = Kiosk.configuration.min_client
        headers
      end

      # Build a fresh headers hash with the three Kiosk headers set.
      #
      # NO CALLER IN THIS REPOSITORY: {HeadersMiddleware} mutates the Rack hash
      # it is handed, through {add_to} above. This is the public no-hash
      # spelling of the same three headers, and its example is the builder half
      # of the Section 3.6 conformance evidence.
      def self.build(server_version: Kiosk::Server::VERSION)
        add_to({}, server_version: server_version)
      end

      # The `Vary` a wire response MUST carry (spec §3.7.1). THREE request
      # headers change the answer and none of them is in the URL:
      # `Authorization` (every wire response is identity-scoped), `Kiosk-PoW`
      # (a tolled 200 and its 402 differ ONLY by this header) and
      # `Kiosk-Timezone` (a bare `YYYY-MM-DD` argument is read in the caller's
      # declared calendar, so two callers on two clocks can send the same URL
      # and mean two different days).
      #
      # Without the second, a private cache keyed on the URL serves a paid 200
      # to an unpaid retry — defeating the toll — or a stale 402 to a paid one,
      # which is an infinite retry loop. Without the third, one assistant's
      # cache hands a delivery window computed for Sydney's tomorrow to the same
      # human's call from Lisbon.
      WIRE_VARY = %w[Authorization Kiosk-PoW Kiosk-Timezone].freeze

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
      #     therefore never re-challenged. Reachable from a handler:
      #     {HandlerDispatch} carries the handler's own `Cache-Control` out
      #     to here.
      #   * `Cache-Control` NAMING A SHARED CACHE — refused. See
      #     {.shared_cacheable?} below.
      #
      # @param headers [Hash] the response headers to mutate
      # @param status  [Integer] the HTTP status being rendered
      def self.add_cache_policy(headers, status:)
        present = headers["Vary"].to_s.split(",").map { |t| t.strip }.reject(&:empty?)
        missing = WIRE_VARY.reject { |t| present.any? { |p| p.casecmp?(t) } }
        headers["Vary"] = (present + missing).join(", ")

        operator = headers["Cache-Control"].to_s
        if status.to_i == 402
          headers["Cache-Control"] = "no-store"
        elsif operator.empty?
          headers["Cache-Control"] = "private, no-store"
        elsif shared_cacheable?(operator)
          refuse_shared_cache(operator)
          headers["Cache-Control"] = "private, no-store"
        end
        headers
      end

      # §3.7.3, ENFORCED RATHER THAN MERELY UNBREAKABLE.
      #
      # "An operator MUST NOT send `public` or `s-maxage` on a verb response.
      # Shared caching of an identity-scoped payload is a cross-tenant leak."
      # A handler's own `Cache-Control` reaches the wire ({HandlerDispatch}),
      # so §3.7.4's permission and §3.7.3's prohibition arrive by the same
      # road — which is what makes the prohibition a check to run rather than
      # a property of a seam that discarded every header a handler set.
      #
      # IT REFUSES THE VALUE RATHER THAN EDITING IT. Stripping `public` out of
      # `public, max-age=600` would hand back `private, max-age=600` — a policy
      # nobody wrote, guessing that a handler which asked for a shared cache
      # meant a private one of the same length. This seam does not guess
      # anywhere else (see {HandlerDispatch#wire_error}, which refuses to pick
      # between two error codes that share a status), so it does not guess
      # here: the wire's own `private, no-store` applies and the operator is
      # TOLD, once per offending response, with the value they sent.
      #
      # THE LIST IS RFC 9111 §3.5's, AND IT IS ALSO §3.7.3's.
      # That default is: a shared cache MUST NOT reuse a response to a request
      # carrying `Authorization` UNLESS the response names one of `public`,
      # `s-maxage` **or `must-revalidate`**. Every verb request carries
      # `Authorization` (there is no anonymous verb — §3, point 2), so those
      # three directives are exactly the set that opens the door, and the third
      # is as much of a cross-tenant leak as the other two. `private,
      # max-age=N` remains the one relaxation §3.7.4 allows.
      SHARED_CACHE_DIRECTIVES = /\b(?:public|s-maxage|must-revalidate)\b/i

      def self.shared_cacheable?(cache_control)
        SHARED_CACHE_DIRECTIVES.match?(cache_control.to_s)
      end

      def self.refuse_shared_cache(value)
        message =
          "[kiosk-server] refused a shared-cache policy on a wire response: " \
          "Cache-Control: #{value.inspect}. Spec §3.7.3 forbids `public`, " \
          "`s-maxage` and `must-revalidate` on a verb response — RFC 9111 " \
          "§3.5 makes those three the directives that let a shared cache " \
          "reuse an answer to an authenticated request, and the payload is " \
          "scoped to one identity, so any of them would hand it to another " \
          "caller. " \
          "Sent `private, no-store` instead; `private, max-age=N` is the " \
          "relaxation §3.7.4 allows."
        logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
        logger ? logger.warn(message) : warn(message)
      end

      # ── THE WRITTEN EXCEPTION to the policy above ────────────────────────
      #
      # `GET <endpoint>/schema` and `GET <endpoint>/openapi.json` are PUBLIC:
      # both carry verb names, descriptions and schemas, nothing per-agent and
      # no secret, and both are rendered from in-process state. So the two
      # rules the default encodes stop applying to them, and both must be
      # actively UNDONE rather than merely relaxed:
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
      # WHY THE SHORT ONE IS SIXTY SECONDS. The number is not a
      # cache-efficiency knob; it is the length of time an operator has to live
      # with AFTER A DEPLOY, during which some callers still hold the previous
      # pointer document and follow the previous `?v=` link. A minute of
      # post-deploy staleness is what this wire is willing to serve. The load
      # side of the trade is NOT paid by this number — it is paid by
      # {IMMUTABLE_MAX_AGE} on the versioned URL, which is where the bytes
      # actually are, because an assistant follows the link from the pointer
      # rather than re-fetching the catalogue itself. Raising it trades
      # post-deploy staleness for nothing: the backend load a longer TTL would
      # save is already saved on the versioned URL.
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
      # IT SETS NO `Vary`, AND THAT IS THE POINT. These documents are public:
      # one answer, the same for every caller, whatever they sent.
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
