# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # Registry of named queries — the sanctioned read surface that replaces raw
    # SQL. Agents call them by name with params (never SQL); the registered
    # handler runs the actual query with bound params. "Read-only" is a
    # convention the provider upholds (the registry does not enforce it), but the
    # agent can only ever supply a query name + param values — never SQL — so the
    # no-agent-SQL property holds regardless of what a handler does.
    #
    # ONE WAY IN (K-495 / T-053 / T-081). A verb is declared by `include
    # Kiosk::Query` in a controller the operator owns, where class-level macros
    # bind to the next-defined method and the handler is an ordinary controller
    # action; see {Kiosk::Query}. The operator names those classes in
    # `Kiosk.configuration.handlers` and {HandlerRegistrations} — driven by the
    # engine's `to_prepare` — puts them here. It is what all seven demos, the
    # e2e harness and the install generator use.
    #
    # The `register(name) { |args| … }` call this registry used to expose
    # alongside that is GONE (T-081). It was a second shape for the same thing
    # that could not be reloaded, could not be reached by Rails' own filters,
    # rescue_from or params handling, and taught operators — in the very file an
    # adopter copies — that Rails does not apply to their wire surface.
    #
    # A handler runs inside a GUC-scoped {SessionContext}, so
    # `kiosk.current_user_id()` and friends are available for per-user scoping.
    #
    # @example reading the registry
    #   Kiosk::Server::Queries.known             # => ["menu"]
    #   Kiosk::Server::Queries.describe("menu")  # => { name:, description:, params:, … }
    #   Kiosk::Server::Queries.catalog           # => sorted Array of descriptors
    #
    # The descriptor fields, all declared as macros on the handler controller.
    # TWO of them are REQUIRED of every verb — `schema-descriptor.schema.json`
    # lists `input_schema` and `output_schema` in the descriptor's `required`,
    # protocol.md Section 8.3 says both are REQUIRED, and {HandlerMixin} raises
    # at class-body load for a declaration missing either (T-073 = A, landed by
    # T-068; K-598 / K-671 / K-680):
    #   description:    prose semantics — what this verb does and what the result
    #                   MEANS. Never a field list or a type (ADR-0023 / K-500).
    #   input_schema:   REQUIRED. A JSON-Schema object describing this query's
    #                   INPUTS (required/optional, types, enums, ranges). THE
    #                   input contract — every name and type lives here, and the
    #                   operator validates against it before the handler runs.
    #                   A query that takes nothing declares the closed empty
    #                   object, so "takes no arguments" is published rather than
    #                   inferred from an absence.
    #   output_schema:  REQUIRED. A JSON Schema for the rows this query RETURNS.
    #                   With no response envelope since 0.4 this is the ONLY
    #                   machine-readable statement of the result shape; a query's
    #                   is an ARRAY schema whether or not it paginates.
    #   example_params: OPTIONAL. An example params object an assistant can copy
    #                   verbatim. It ILLUSTRATES input_schema, and loses to it.
    #   example_row:    OPTIONAL. An example of ONE row this query returns. It
    #                   ILLUSTRATES output_schema, and loses to it.
    #
    # `params` — the free-text hint ADR-0023 retired — is not a macro at all.
    module Queries
      # Internal entry holding a handler (callable) plus optional discovery metadata.
      # Defined at module scope so reset! can replace @registry without affecting the
      # constant. Not part of the public API — callers always go through fetch/describe/catalog.
      Entry = Data.define(:handler, :description, :input_schema, :output_schema,
                          :example_params, :example_row)

      class << self
        # Records ONE declared verb. The {HandlerMixin} is the only caller:
        # operators declare verbs with the macros, never by calling this.
        #
        # @api private
        # @param name [String, Symbol] the wire name
        # @param handler [#call] the {HandlerDispatch} for the declaring method
        # @return [Entry] the recorded entry
        def declare(name, handler, description: nil, input_schema: nil,
                    output_schema: nil, example_params: nil, example_row: nil)
          registry[name.to_s] = Entry.new(
            handler: handler, description: description,
            input_schema: input_schema, output_schema: output_schema,
            example_params: example_params, example_row: example_row,
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
        #   { name: String, description: String|nil, params: nil }
        # plus, ONLY when the operator declared them, the ADR-0021 machine-readable
        # keys `input_schema`, `output_schema`, `example_params`, `example_row`.
        # Absent keys are omitted entirely, so an undeclared extension is absent
        # rather than a null an assistant has to interpret.
        #
        # `params` — the free-text hint ADR-0023 retired — is always nil: no macro
        # declares it and nothing can set it. The KEY stays because the slot is
        # part of the published descriptor shape (spec §8.3, "the slot survives on
        # the wire only so descriptors written before the retirement stay valid"),
        # and dropping it would change every descriptor this implementation
        # serves. Whether to drop the slot is a WIRE decision, not this one.
        def describe(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown query: #{name.inspect}",
              hint: not_found_hint(name),
            )
          end
          descriptor = { name: name.to_s, description: entry.description, params: nil }
          descriptor[:input_schema]   = entry.input_schema   unless entry.input_schema.nil?
          descriptor[:output_schema]  = entry.output_schema  unless entry.output_schema.nil?
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

        # Removes ONE registration, if it is there. The mixin's rebuild
        # ({HandlerRegistrations}) is the caller: a verb deleted from a handler
        # controller has to leave the catalog AND stop being served, and
        # `declare` alone can only overwrite. Returns the dropped Entry, or
        # nil when the name was not registered.
        def unregister(name)
          registry.delete(name.to_s)
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
