# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # Registry of named queries — the sanctioned read surface that replaces raw
    # SQL. Agents call them by name with params (never SQL); the registered block
    # runs the actual query with bound params. "Read-only" is a convention the
    # provider upholds (the registry does not enforce it), but the agent can only
    # ever supply a query name + param values — never SQL — so the no-agent-SQL
    # property holds regardless of what a block does.
    #
    # The block receives the agent-supplied params (a symbolized Hash, with
    # `:name` already stripped by the Executor) and returns rows (Array<Hash>)
    # or any value. It runs inside a GUC-scoped {SessionContext}, so
    # `kiosk.current_user_id()` and friends are available for per-user scoping.
    #
    # @example
    #   Kiosk::Server::Queries.register("menu") { |p| Menu.where(active: true).as_json }
    #   Kiosk::Server::Queries.fetch("menu").call({})
    #
    # Optional metadata for agent self-discovery (backward-compatible):
    #   Kiosk::Server::Queries.register("menu", description: "Browse the menu",
    #                                            params: { restaurant_id: "string" }) { ... }
    #   Kiosk::Server::Queries.describe("menu")  # => { name:, description:, params: }
    #   Kiosk::Server::Queries.catalog           # => sorted Array of descriptors
    module Queries
      # Internal entry holding a handler (callable) plus optional discovery metadata.
      # Defined at module scope so reset! can replace @registry without affecting the
      # constant. Not part of the public API — callers always go through fetch/describe/catalog.
      Entry = Data.define(:handler, :description, :params)

      class << self
        def register(name, callable = nil, description: nil, params: nil, &block)
          handler = callable || block
          raise ArgumentError, "register requires a callable or a block" if handler.nil?

          registry[name.to_s] = Entry.new(handler: handler, description: description, params: params)
        end

        def fetch(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown query: #{name.inspect}",
              hint: "Known queries: #{registry.keys.inspect}",
            )
          end
          entry.handler
        end

        # Returns a descriptor Hash for the named query:
        #   { name: String, description: String|nil, params: any|nil }
        def describe(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown query: #{name.inspect}",
              hint: "Known queries: #{registry.keys.inspect}",
            )
          end
          { name: name.to_s, description: entry.description, params: entry.params }
        end

        # Returns all registered queries as an Array of descriptor Hashes, sorted by name.
        def catalog
          registry.keys.sort.map { |name| describe(name) }
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
