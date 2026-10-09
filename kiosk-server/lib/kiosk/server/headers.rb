# frozen_string_literal: true

module Kiosk
  module Server
    # The Kiosk response headers and the cache policy of a wire response.
    module Headers
      # Min-Client comes from configuration so it matches `kiosk.min_client`
      # in the discovery document.
      def self.add_to(headers, server_version: Kiosk::Server::VERSION)
        headers[Kiosk::Protocol::HEADER_SERVER_VERSION] = server_version
        headers[Kiosk::Protocol::HEADER_API_VERSION]    = Kiosk::Protocol::API_VERSION
        headers[Kiosk::Protocol::HEADER_MIN_CLIENT]     = Kiosk.configuration.min_client
        headers
      end

      def self.build(server_version: Kiosk::Server::VERSION)
        add_to({}, server_version: server_version)
      end

      # §3.7.1: every one of these changes the answer and none is in the URL.
      WIRE_VARY = %w[Authorization Kiosk-PoW Kiosk-Timezone].freeze

      # Adds the wire `Vary`; forces `no-store` on a 402; defaults to
      # `private, no-store` and refuses a shared-cache directive (§3.7.3).
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

      # RFC 9111 §3.5: the directives that let a shared cache reuse an answer
      # to an authenticated request.
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

      # The public documents (`/schema`, `/openapi.json`): a short TTL on the
      # fixed URL, a year on the digest-versioned `?v=` one.
      SHORT_MAX_AGE     = 60
      IMMUTABLE_MAX_AGE = 31_536_000

      # Spelt in the order ActionDispatch re-emits the header.
      PUBLIC_SHORT     = "max-age=#{SHORT_MAX_AGE}, public"
      PUBLIC_IMMUTABLE = "max-age=#{IMMUTABLE_MAX_AGE}, public, immutable"

      # Sets no `Vary`: a public document has one answer for every caller.
      def self.add_public_cache_policy(headers, etag:, immutable:)
        headers["Cache-Control"] = immutable ? PUBLIC_IMMUTABLE : PUBLIC_SHORT
        headers["ETag"] = etag
        headers
      end
    end
  end
end
