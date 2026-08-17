# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # Process-wide registry of Action handlers: a name -> callable map plus the
    # descriptor metadata documented below.
    #
    # ONE WAY IN (K-495 / T-053 / T-081). A verb is declared by `include
    # Kiosk::Action` in a controller the operator owns, where class-level macros
    # bind to the next-defined method and the handler is an ordinary controller
    # action; see {Kiosk::Action}. The operator names those classes in
    # `Kiosk.configuration.handlers` and {HandlerRegistrations} — driven by the
    # engine's `to_prepare` — puts them here. It is what all seven demos, the
    # e2e harness and the install generator use.
    #
    # The `register(name) { |args| … }` call this registry used to expose
    # alongside that is GONE (T-081); {Queries} carries the reasoning.
    #
    # @example reading the registry
    #   Kiosk::Server::Actions.known                   # => ["place_order"]
    #   Kiosk::Server::Actions.describe("place_order") # => { name:, description:, params:, … }
    #   Kiosk::Server::Actions.catalog                 # => sorted Array of descriptors
    #
    # The descriptor fields, all declared as macros on the handler controller
    # and all OPTIONAL (a descriptor that sets none of them carries name +
    # description + params only):
    #   description:    prose semantics — what this verb does, what it CHANGES,
    #                   and what the result MEANS. Never a field list or a type
    #                   (ADR-0023 / K-500).
    #   input_schema:   a JSON-Schema object describing this action's INPUTS
    #                   (required/optional, types, enums, ranges). Under ADR-0023
    #                   this is THE input contract — every name and type lives here.
    #   output_schema:  a JSON Schema for what the action RETURNS, so an assistant
    #                   knows the result shape without a call-and-observe probe
    #                   (ADR-0023 / K-500). Its exact envelope composition is
    #                   settled when T-050 lands the first one.
    #   example_params: an example params object an assistant can copy verbatim.
    #   example_row:    an example of this action's return value, so an assistant
    #                   learns the result shape without a call-and-observe probe.
    module Actions
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
              "Unknown action: #{name.inspect}",
              hint: not_found_hint(name),
            )
          end
          entry.handler
        end

        # Returns a descriptor Hash for the named action:
        #   { name: String, description: String|nil, params: nil }
        # plus, ONLY when the operator declared them, the ADR-0021 machine-readable
        # keys `input_schema`, `output_schema`, `example_params`, `example_row`.
        # Absent keys are omitted entirely. `params` is always nil and the key
        # stays for wire compatibility — {Queries#describe} carries the reasoning.
        def describe(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown action: #{name.inspect}",
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
        # bloat the envelope) and always points at the schema verb, so an
        # assistant that mistyped a name can self-correct WITHOUT a schema
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
