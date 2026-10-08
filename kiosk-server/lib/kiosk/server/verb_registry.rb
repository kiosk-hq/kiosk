# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/schema_slots"

module Kiosk
  module Server
    # What a verb registry IS, written once: a process-wide name → handler map
    # plus the descriptor metadata an origin publishes for each name. {Queries}
    # and {Actions} are the two registries, and each is this module plus one
    # word — its `SCOPE`, which is also the noun its refusals use.
    #
    # ONE WAY IN. A verb is declared by `include Kiosk::Handler` in a controller
    # the operator owns, where class-level macros bind to the next-defined method
    # and the handler is an ordinary controller action; `kind :query` / `kind
    # :action` is what decides which registry it lands in, and the same class may
    # declare both. See {Kiosk::Handler} and {HandlerRegistrations}.
    #
    # A handler runs inside a GUC-scoped {SessionContext}, so
    # `kiosk.current_user_id()` and friends are available for per-user scoping.
    #
    # The descriptor fields, all declared as macros on the handler controller.
    # TWO of them are REQUIRED of every verb — `schema-descriptor.schema.json`
    # lists `input_schema` and `output_schema` in the descriptor's `required`,
    # protocol.md Section 8.3 says both are REQUIRED, and {HandlerMixin} raises
    # at class-body load for a declaration missing either:
    #   reach:          REQUIRED, and DEFAULTED. Whose rows this verb may touch
    #                   (spec §7.2): `principal` (the default and the
    #                   norm — only the caller's own rows, or rows that belong to
    #                   no principal), `published`, `consented` or `role`. A
    #                   declaration that says nothing means `principal`, so the
    #                   absolute case costs an operator no ceremony and every
    #                   DEPARTURE from it is a line somebody wrote on purpose.
    #                   Always published in the descriptor, never omitted: "this
    #                   verb is scoped to you" is a fact an assistant should read
    #                   rather than infer from a missing key.
    #   description:    prose semantics — what this verb does, what it CHANGES if
    #                   it changes anything, and what the result MEANS. Never a
    #                   field list or a type.
    #   input_schema:   REQUIRED. A JSON-Schema object describing this verb's
    #                   INPUTS (required/optional, types, enums, ranges). THE
    #                   input contract — every name and type lives here, and the
    #                   operator validates against it before the handler runs. A
    #                   verb that takes nothing declares the closed empty object,
    #                   so "takes no arguments" is published rather than inferred
    #                   from an absence.
    #   output_schema:  REQUIRED. A JSON Schema for what the verb RETURNS. With
    #                   no response envelope this is the ONLY machine-readable
    #                   statement of the result shape; a QUERY's is an ARRAY
    #                   schema whether or not it paginates.
    #   example_params: OPTIONAL. An example params object an assistant can copy
    #                   verbatim. It ILLUSTRATES input_schema, and loses to it.
    #   example_row:    OPTIONAL. An example of ONE row a query returns, or of an
    #                   action's return value. It ILLUSTRATES output_schema, and
    #                   loses to it.
    module VerbRegistry
      # Internal entry holding a handler (callable) plus optional discovery
      # metadata. Defined at module scope so reset! can replace @registry without
      # affecting the constant. Not part of the public API — callers always go
      # through fetch/describe/catalog.
      Entry = Data.define(:handler, :reach, :description, :input_schema, :output_schema,
                          :example_params, :example_row)

      # Records ONE declared verb. The {HandlerMixin} is the only caller:
      # operators declare verbs with the macros, never by calling this.
      #
      # @api private
      # @param name [String, Symbol] the wire name
      # @param handler [#call] the {HandlerDispatch} for the declaring method
      # @return [Entry] the recorded entry
      def declare(name, handler, reach: HandlerMixin::DEFAULT_REACH, description: nil,
                  input_schema: nil, output_schema: nil, example_params: nil,
                  example_row: nil)
        # A declaration whose schema slots carry a proc puts this origin on
        # the resolving path. STRUCTURAL: it looks for procs, it
        # never calls one — a class body is read at `db:create` too.
        SchemaSlots.note_declaration(
          input_schema: input_schema, output_schema: output_schema,
          example_params: example_params, example_row: example_row,
        )
        registry[name.to_s] = Entry.new(
          handler: handler, reach: reach, description: description,
          input_schema: input_schema, output_schema: output_schema,
          example_params: example_params, example_row: example_row,
        )
      end

      def fetch(name)
        entry(name).handler
      end

      # Returns a descriptor Hash for the named verb:
      #   { name: String, description: String|nil, reach: String }
      # plus, ONLY when the operator declared them, the machine-readable keys
      # `input_schema`, `output_schema`, `example_params`, `example_row`.
      # Absent keys are omitted entirely, so an undeclared extension is absent
      # rather than a null an assistant has to interpret.
      def describe(name)
        found = entry(name)
        # A slot may be a PROC — a schema derived from the operator's
        # own rows, `enum: -> { Category.pluck(:slug) }`. {SchemaSlots}
        # resolves it lazily and memoizes it with a lifetime, so an operator
        # who adds a row does not have to redeploy to publish it, and the
        # proc is not called on the per-request validation path. With no
        # proc anywhere on the origin it yields straight through.
        SchemaSlots.descriptor(self::SCOPE, name, found) do
          descriptor = { name: name.to_s, description: found.description,
                         reach: found.reach.to_s }
          descriptor[:input_schema]   = found.input_schema   unless found.input_schema.nil?
          descriptor[:output_schema]  = found.output_schema  unless found.output_schema.nil?
          descriptor[:example_params] = found.example_params unless found.example_params.nil?
          descriptor[:example_row]    = found.example_row    unless found.example_row.nil?
          descriptor
        end
      end

      # Every registered verb as an Array of descriptor Hashes, sorted by name.
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

      # The registered entry, or the 404 this registry raises for an unknown
      # name. The hint names the registered names (sorted, capped at
      # MAX_HINT_NAMES + "…" so a large surface cannot bloat the problem
      # document) and always points at the schema verb, so an assistant that
      # mistyped a name (`listings` for `browse_listings`) can self-correct
      # WITHOUT a schema round-trip. The names are already public via
      # GET .../schema, so listing them here leaks nothing new.
      def entry(name)
        registry.fetch(name.to_s) do
          raise Errors::VerbNotFound.new(
            "Unknown #{self::SCOPE}: #{name.inspect}",
            hint: Errors.unknown_name_hint(name, self::SCOPE.to_s, registry.keys.sort),
          )
        end
      end

      def registry
        @registry ||= {}
      end
    end
  end
end
