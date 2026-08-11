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
      def with(identity: nil, env: nil)
        previous = Thread.current[KEY]
        Thread.current[KEY] = { identity: identity, env: env }
        yield
      ensure
        Thread.current[KEY] = previous
      end

      # @return [Kiosk::Identity, nil]
      def identity = current[:identity]

      # @return [Hash, nil] the OUTER Rack env (the wire request), never the
      #   handler sub-request's env.
      def env = current[:env]

      def current = Thread.current[KEY] || EMPTY
    end
  end
end
