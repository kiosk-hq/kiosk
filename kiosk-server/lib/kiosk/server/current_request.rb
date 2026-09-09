# frozen_string_literal: true

module Kiosk
  module Server
    # The wire request currently being served, as seen from BELOW the
    # {Executor} — i.e. from inside a handler.
    #
    # {WireController} resolves the identity and holds the real Rack env, but
    # the registry contract is a plain `callable.call(args)` with no room for
    # either. Rather than widen that contract (which every existing `register`
    # block in the demos depends on), the two are carried here, block-scoped,
    # for the duration of one dispatch. {HandlerDispatch} reads them when it
    # builds the sub-request env for a controller-backed handler.
    #
    #   CurrentRequest.with(identity: identity, env: request.env) do
    #     Executor.call(...)
    #   end
    #
    # Deliberately NOT an ActiveSupport::CurrentAttributes: that relies on the
    # Rails executor to reset it between requests, and this carrier is also used
    # from the RLS journey DSL and from unit specs, which run no executor. A
    # block-scoped set/restore leaks nothing in any of those hosts.
    #
    # `Thread.current[]` is FIBER-local, so a handler that hands work to another
    # thread or fiber does not see it — such a handler must close over what it
    # needs, exactly as it must for a database connection.
    module CurrentRequest
      KEY   = :kiosk_server_current_request
      EMPTY = {}.freeze

      module_function

      # Runs `block` with `identity` / `env` visible to handlers. Restores the
      # previous values (nesting is safe; an inner `with` that omits a value
      # BLANKS it rather than inheriting it — pass it through explicitly).
      #
      # `handler_headers` is the ONE slot that carries data back UP:
      # the caller passes a hash it still holds, {HandlerDispatch} writes the
      # handler's own response headers into it, and the wire reads it after the
      # block returns. It is here rather than on {Result} for the same reason
      # `identity` and `env` are: the registry contract is a plain
      # `callable.call(args)` and there is no room in it for either direction.
      def with(identity: nil, env: nil, handler_headers: nil, timezone: nil)
        previous = Thread.current[KEY]
        Thread.current[KEY] = { identity: identity, env: env, handler_headers: handler_headers,
                                timezone: timezone }
        yield
      ensure
        Thread.current[KEY] = previous
      end

      # @return [Kiosk::Identity, nil]
      def identity = current[:identity]

      # @return [Hash, nil] the OUTER Rack env (the wire request), never the
      #   handler sub-request's env.
      def env = current[:env]

      # @return [Hash, nil] the sink the wire wants a handler's own response
      #   headers written into, or nil when nobody is collecting (a direct
      #   {Executor} call, an RLS journey test).
      def handler_headers = current[:handler_headers]

      # THE CALLER'S OWN CLOCK, already parsed and validated by
      # {CallerTimezone} — the zone a bare `YYYY-MM-DD` ARGUMENT is read in.
      #
      # `nil` means the caller declared none, which is the common case and is
      # not an error: the operator then reads the argument on the clock of the
      # place the service happens and SAYS SO in the row. It never decides how
      # an answer is RENDERED — that zone belongs to the serviced resource,
      # which is operator data this gem knows nothing about.
      #
      # @return [ActiveSupport::TimeZone, nil]
      def timezone = current[:timezone]

      def current = Thread.current[KEY] || EMPTY
    end
  end
end
