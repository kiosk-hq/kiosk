# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # Registry of read-only named queries. Agents call them by name with params
    # (never SQL); the registered block runs the actual query with bound params —
    # this is the sanctioned read surface that replaces raw SQL.
    #
    # The block receives the agent-supplied params (a symbolized Hash, with
    # `:name` already stripped by the Executor) and returns rows (Array<Hash>)
    # or any value. It runs inside a GUC-scoped {SessionContext}, so
    # `kiosk.current_user_id()` and friends are available for per-user scoping.
    #
    # @example
    #   Kiosk::Server::Queries.register("menu") { |p| Menu.where(active: true).as_json }
    #   Kiosk::Server::Queries.fetch("menu").call({})
    module Queries
      class << self
        def register(name, callable = nil, &block)
          handler = callable || block
          raise ArgumentError, "register requires a callable or a block" if handler.nil?

          registry[name.to_s] = handler
        end

        def fetch(name)
          registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown query: #{name.inspect}",
              hint: "Known queries: #{registry.keys.inspect}",
            )
          end
        end

        def known
          registry.keys
        end

        def reset!
          @registry = nil
        end

        private

        def registry
          @registry ||= {}
        end
      end
    end
  end
end
