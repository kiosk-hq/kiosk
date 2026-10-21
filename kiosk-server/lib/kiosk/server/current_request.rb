# frozen_string_literal: true

module Kiosk
  module Server
    # The protocol request being dispatched, visible to its handler for the duration
    # of one block. Fiber-local: a handler that hands work to another thread must
    # pass what it needs.
    module CurrentRequest
      KEY   = :kiosk_server_current_request
      EMPTY = {}.freeze

      module_function

      # An inner `with` blanks what it omits.
      def with(identity: nil, timezone: nil)
        previous = Thread.current[KEY]
        Thread.current[KEY] = { identity: identity, timezone: timezone }
        yield
      ensure
        Thread.current[KEY] = previous
      end

      def identity = current[:identity]

      # The caller's {CallerTimezone}, or nil when it declared none.
      def timezone = current[:timezone]

      def current = Thread.current[KEY] || EMPTY
    end
  end
end
