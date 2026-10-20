# frozen_string_literal: true

module Kiosk
  module Server
    # The Kiosk response headers and the cache policy of a wire response.
    module Headers
      def self.add_to(headers, server_version: Kiosk::Server::VERSION)
        headers[Kiosk::Protocol::HEADER_SERVER_VERSION] = server_version
        headers[Kiosk::Protocol::HEADER_API_VERSION]    = Kiosk::Protocol::API_VERSION
        headers[Kiosk::Protocol::HEADER_MIN_CLIENT]     = Kiosk::Protocol::MIN_CLIENT
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
        add_wire_vary(headers)
        policy = wire_cache_control(headers['Cache-Control'].to_s, status)
        headers['Cache-Control'] = policy if policy
        headers
      end

      def self.add_wire_vary(headers)
        present = headers['Vary'].to_s.split(',').map(&:strip).reject(&:empty?)
        missing = WIRE_VARY.reject { |t| present.any? { |p| p.casecmp?(t) } }
        headers['Vary'] = (present + missing).join(', ')
      end

      # nil keeps the operator's own policy.
      def self.wire_cache_control(operator, status)
        return 'no-store' if status.to_i == 402
        return 'private, no-store' if operator.empty?
        return unless shared_cacheable?(operator)

        refuse_shared_cache(operator)
        'private, no-store'
      end

      # RFC 9111 §3.5: the directives that let a shared cache reuse an answer
      # to an authenticated request.
      SHARED_CACHE_DIRECTIVES = /\b(?:public|s-maxage|must-revalidate)\b/i

      def self.shared_cacheable?(cache_control)
        SHARED_CACHE_DIRECTIVES.match?(cache_control.to_s)
      end

      SHARED_CACHE_RULE =
        'A verb response is for one caller, so a shared cache must not keep it. ' \
        'Sent `private, no-store` instead; send `private, max-age=N` to let the caller cache it.'

      def self.refuse_shared_cache(value)
        message = '[kiosk-server] refused a shared-cache policy on a wire response: ' \
                  "Cache-Control: #{value.inspect}. #{SHARED_CACHE_RULE}"
        logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
        logger ? logger.warn(message) : warn(message)
      end

      # The public documents (`/schema`, `/openapi.json`): a short TTL on the
      # fixed URL, a year on the digest-versioned `?v=` one.
      SHORT_MAX_AGE     = 60
      IMMUTABLE_MAX_AGE = 31_536_000

      # Spelt in the order ActionDispatch re-emits the header.
      PUBLIC_SHORT     = "max-age=#{SHORT_MAX_AGE}, public".freeze
      PUBLIC_IMMUTABLE = "max-age=#{IMMUTABLE_MAX_AGE}, public, immutable".freeze

      # Sets no `Vary`: a public document has one answer for every caller.
      def self.add_public_cache_policy(headers, etag:, immutable:)
        headers['Cache-Control'] = immutable ? PUBLIC_IMMUTABLE : PUBLIC_SHORT
        headers['ETag'] = etag
        headers
      end
    end
  end
end
