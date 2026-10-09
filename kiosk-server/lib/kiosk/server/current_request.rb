# frozen_string_literal: true

module Kiosk
  module Server
    # The wire request being dispatched, visible to its handler for the duration
    # of one block. Fiber-local: a handler that hands work to another thread must
    # pass what it needs.
    module CurrentRequest
      KEY   = :kiosk_server_current_request
      EMPTY = {}.freeze

      module_function

      # An inner `with` blanks what it omits. `handler_headers` is a hash the
      # handler's response headers are written into, for the caller to read after.
      def with(identity: nil, env: nil, handler_headers: nil, timezone: nil)
        previous = Thread.current[KEY]
        Thread.current[KEY] = { identity: identity, env: env, handler_headers: handler_headers,
                                timezone: timezone }
        yield
      ensure
        Thread.current[KEY] = previous
      end

      def identity = current[:identity]

      # The wire request's Rack env, not the handler sub-request's.
      def env = current[:env]

      def handler_headers = current[:handler_headers]

      # The caller's {CallerTimezone}, or nil when it declared none.
      def timezone = current[:timezone]

      def current = Thread.current[KEY] || EMPTY
    end
  end
end
