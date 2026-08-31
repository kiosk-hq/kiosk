# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/schema_slots"

module Kiosk
  module Server
    # Process-wide registry of Action handlers: a name -> callable map plus the
    # descriptor metadata documented below.
    #
    # ONE WAY IN (K-495 / T-053 / T-081). A verb is declared by `include
    # Kiosk::Handler` in a controller the operator owns, where class-level macros
    # bind to the next-defined method and the handler is an ordinary controller
    # action; `kind :action` is what puts it HERE rather than in {Queries}, and
    # the same class may declare both (K-921). See {Kiosk::Handler}. The
    # operator names those classes in
    # `Kiosk.configuration.handlers` and {HandlerRegistrations} — driven by the
    # engine's `to_prepare` — puts them here. It is what all seven demos, the
    # e2e harness and the install generator use.
    #
    # The `register(name) { |args| … }` call this registry used to expose
    # alongside that is GONE (T-081); {Queries} carries the reasoning.
    #
    # @example reading the registry
    #   Kiosk::Server::Actions.known                   # => ["place_order"]
    #   Kiosk::Server::Actions.describe("place_order") # => { name:, description:, reach:, … }
    #   Kiosk::Server::Actions.catalog                 # => sorted Array of descriptors
    #
    # The descriptor fields, all declared as macros on the handler controller.
    # TWO of them are REQUIRED of every verb — `schema-descriptor.schema.json`
    # lists `input_schema` and `output_schema` in the descriptor's `required`,
    # protocol.md Section 8.3 says both are REQUIRED, and {HandlerMixin} raises
    # at class-body load for a declaration missing either (T-073 = A, landed by
    # T-068; K-598 / K-671 / K-680):
    #   reach:          REQUIRED, and DEFAULTED. Whose rows this verb may touch
    #                   (spec §7.2, ADR-0028): `principal` (the default and the
    #                   norm — only the caller's own rows, or rows that belong to
    #                   no principal), `published`, `consented` or `role`. A
    #                   declaration that says nothing means `principal`, so the
    #                   absolute case costs an operator no ceremony and every
    #                   DEPARTURE from it is a line somebody wrote on purpose.
    #                   Always published in the descriptor, never omitted: "this
    #                   verb is scoped to you" is a fact an assistant should read
    #                   rather than infer from a missing key.
    #   description:    prose semantics — what this verb does, what it CHANGES,
    #                   and what the result MEANS. Never a field list or a type
    #                   (ADR-0023 / K-500).
    #   input_schema:   REQUIRED. A JSON-Schema object describing this action's
    #                   INPUTS (required/optional, types, enums, ranges). THE
    #                   input contract — every name and type lives here, and the
    #                   operator validates against it before the handler runs.
    #                   An action that takes nothing declares the closed empty
    #                   object.
    #   output_schema:  REQUIRED. A JSON Schema for what the action RETURNS.
    #                   With no response envelope since 0.4 this is the ONLY
    #                   machine-readable statement of the result shape.
    #   example_params: OPTIONAL. An example params object an assistant can copy
    #                   verbatim. It ILLUSTRATES input_schema, and loses to it.
    #   example_row:    OPTIONAL. An example of this action's return value. It
    #                   ILLUSTRATES output_schema, and loses to it.
    #
    # `params` — the free-text hint ADR-0023 retired — is not a macro, and since
    # T-085 it is not a descriptor key either: spec §8.3 removed the slot.
    module Actions
      # Which registry a memoized descriptor belongs to ({SchemaSlots}).
      SCOPE = :action

      # Internal entry holding a handler (callable) plus optional discovery metadata.
      # Defined at module scope so reset! can replace @registry without affecting the
      # constant. Not part of the public API — callers always go through fetch/describe/catalog.
      Entry = Data.define(:handler, :reach, :description, :input_schema, :output_schema,
                          :example_params, :example_row)

      class << self
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
          # the resolving path (K-922). STRUCTURAL: it looks for procs, it
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
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown action: #{name.inspect}",
              hint: not_found_hint(name),
            )
          end
          entry.handler
        end

        # Returns a descriptor Hash for the named action:
        #   { name: String, description: String|nil, reach: String }
        # plus, ONLY when the operator declared them, the ADR-0021 machine-readable
        # keys `input_schema`, `output_schema`, `example_params`, `example_row`.
        # Absent keys are omitted entirely. `params` is GONE from the descriptor
        # (spec §8.3, T-085) — {Queries#describe} carries the reasoning.
        def describe(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown action: #{name.inspect}",
              hint: not_found_hint(name),
            )
          end
          # A slot may be a PROC (K-922) — a schema derived from the operator's
          # own rows, `enum: -> { Category.pluck(:slug) }`. {SchemaSlots}
          # resolves it lazily and memoizes it with a lifetime, so an operator
          # who adds a row does not have to redeploy to publish it, and the
          # proc is not called on the per-request validation path. With no
          # proc anywhere on the origin it yields straight through.
          SchemaSlots.descriptor(SCOPE, name, entry) do
            descriptor = { name: name.to_s, description: entry.description,
                           reach: entry.reach.to_s }
            descriptor[:input_schema]   = entry.input_schema   unless entry.input_schema.nil?
            descriptor[:output_schema]  = entry.output_schema  unless entry.output_schema.nil?
            descriptor[:example_params] = entry.example_params unless entry.example_params.nil?
            descriptor[:example_row]    = entry.example_row    unless entry.example_row.nil?
            descriptor
          end
        end

        # Returns all registered actions as an Array of descriptor Hashes, sorted by name.
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

        # Recovery hint for an unknown action name. Names the registered action
        # names (sorted, capped at MAX_HINT_NAMES + "…" so a large surface can't
        # bloat the problem document) and always points at the schema verb, so
        # an assistant that mistyped a name can self-correct WITHOUT a schema
        # round-trip. The names are already public via GET .../schema, so
        # listing them here leaks nothing new.
        def not_found_hint(name)
          Errors.unknown_name_hint(name, "action", registry.keys.sort)
        end

        def registry
          @registry ||= {}
        end
      end
    end
  end
end
