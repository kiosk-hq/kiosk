# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # Process-wide registry of Action handlers: a name -> callable map plus the
    # descriptor metadata documented below.
    #
    # TWO WAYS IN, one registry. The Rails-native one (K-495 / T-053) is
    # `include Kiosk::Action` in a controller the operator owns, where
    # class-level macros bind to the next-defined method and the handler is an
    # ordinary controller action; see {Kiosk::Action}. The direct one is the
    # `register` call below — a name + callable — which is what the demo
    # initializers still use until they migrate (T-057). Both land here, and
    # {Executor} cannot tell them apart.
    #
    # @example
    #   Kiosk::Server::Actions.register("ping") { |args| { pong: args[:name] } }
    #   Kiosk::Server::Actions.fetch("ping").call({ name: "world" })
    #   # => { pong: "world" }
    #
    # Optional metadata for agent self-discovery (backward-compatible):
    #   Kiosk::Server::Actions.register("place_order", description: "Place an order",
    #                                                   params: { items: "array" }) { ... }
    #   Kiosk::Server::Actions.describe("place_order") # => { name:, description:, params: }
    #   Kiosk::Server::Actions.catalog                 # => sorted Array of descriptors
    #
    # Machine-readable descriptor extensions (ADR-0021 / T-042, all OPTIONAL and
    # ADDITIVE — a descriptor that sets none of them is byte-for-byte unchanged):
    #   input_schema:   a JSON-Schema object describing this action's INPUTS
    #                   (required/optional, types, enums, ranges). Under ADR-0023
    #                   this is THE input contract — every name and type lives
    #                   here, and `params` (free text) is retired, surviving only
    #                   for the not-yet-migrated callers. Emitted as `input_schema`.
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
      Entry = Data.define(:handler, :description, :params, :input_schema, :output_schema,
                          :example_params, :example_row)

      class << self
        def register(name, callable = nil, description: nil, params: nil,
                     input_schema: nil, output_schema: nil,
                     example_params: nil, example_row: nil, &block)
          handler = callable || block
          raise ArgumentError, "register requires a callable or a block" if handler.nil?

          registry[name.to_s] = Entry.new(
            handler: handler, description: description, params: params,
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
        #   { name: String, description: String|nil, params: any|nil }
        # plus, ONLY when the operator supplied them, the ADR-0021 machine-readable
        # keys `input_schema`, `example_params`, `example_row`. Absent keys are
        # omitted entirely so a descriptor with no extensions is unchanged.
        def describe(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown action: #{name.inspect}",
              hint: not_found_hint(name),
            )
          end
          descriptor = { name: name.to_s, description: entry.description, params: entry.params }
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
        # `register` alone can only overwrite. Returns the dropped Entry, or
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
