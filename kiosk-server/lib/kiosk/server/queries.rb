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
    #
    # Machine-readable descriptor extensions (ADR-0021 / T-042, all OPTIONAL and
    # ADDITIVE — a descriptor that sets none of them is byte-for-byte unchanged):
    #   input_schema:   a JSON-Schema object describing this query's INPUTS
    #                   (required/optional, types, enums, ranges). Supersedes the
    #                   free-text `params` hint for machine validation; `params`
    #                   stays for prose/back-compat. Emitted in the descriptor as
    #                   `input_schema` when present.
    #   example_params: an example params object an assistant can copy verbatim.
    #   example_row:    an example of ONE row this query returns, so an assistant
    #                   learns the result shape without a call-and-observe probe.
    module Queries
      # Internal entry holding a handler (callable) plus optional discovery metadata.
      # Defined at module scope so reset! can replace @registry without affecting the
      # constant. Not part of the public API — callers always go through fetch/describe/catalog.
      Entry = Data.define(:handler, :description, :params, :input_schema, :example_params, :example_row)

      class << self
        def register(name, callable = nil, description: nil, params: nil,
                     input_schema: nil, example_params: nil, example_row: nil, &block)
          handler = callable || block
          raise ArgumentError, "register requires a callable or a block" if handler.nil?

          registry[name.to_s] = Entry.new(
            handler: handler, description: description, params: params,
            input_schema: input_schema, example_params: example_params, example_row: example_row,
          )
        end

        def fetch(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown query: #{name.inspect}",
              hint: not_found_hint(name),
            )
          end
          entry.handler
        end

        # Returns a descriptor Hash for the named query:
        #   { name: String, description: String|nil, params: any|nil }
        # plus, ONLY when the operator supplied them, the ADR-0021 machine-readable
        # keys `input_schema`, `example_params`, `example_row`. Absent keys are
        # omitted entirely so a descriptor with no extensions is unchanged.
        def describe(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown query: #{name.inspect}",
              hint: not_found_hint(name),
            )
          end
          descriptor = { name: name.to_s, description: entry.description, params: entry.params }
          descriptor[:input_schema]   = entry.input_schema   unless entry.input_schema.nil?
          descriptor[:example_params] = entry.example_params unless entry.example_params.nil?
          descriptor[:example_row]    = entry.example_row    unless entry.example_row.nil?
          descriptor
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

        # Recovery hint for an unknown query name. Names the registered query
        # names (sorted, capped at MAX_HINT_NAMES + "…" so a large surface can't
        # bloat the envelope) and always points at the schema verb, so an
        # assistant that mistyped a name (`listings` for `browse_listings`) can
        # self-correct WITHOUT a schema round-trip. The names are already public
        # via GET .../schema, so listing them here leaks nothing new.
        def not_found_hint(name)
          Errors.unknown_name_hint(name, "query", registry.keys.sort)
        end

        def registry
          @registry ||= {}
        end
      end
    end
  end
end
