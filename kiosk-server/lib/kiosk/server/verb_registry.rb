# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/schema_slots"

module Kiosk
  module Server
    # A verb registry: name → handler plus the descriptor an origin publishes.
    # {Queries} and {Actions} are this module plus a `SCOPE`. Verbs are declared
    # through {Kiosk::Handler}; `input_schema` and `output_schema` are required (§8.3).
    module VerbRegistry
      Entry = Data.define(:handler, :reach, :description, :input_schema, :output_schema,
                          :example_params, :example_row)

      # @api private — the {HandlerMixin} is the only caller.
      def declare(name, handler, reach: HandlerMixin::DEFAULT_REACH, description: nil,
                  input_schema: nil, output_schema: nil, example_params: nil,
                  example_row: nil)
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

      # Undeclared optional keys are omitted rather than null.
      def describe(name)
        found = entry(name)
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

      def catalog
        registry.keys.sort.map { |name| describe(name) }
      end

      def known
        registry.keys
      end

      def unregister(name)
        registry.delete(name.to_s)
      end

      def reset!
        @registry = nil
      end

      private

      # The 404's hint lists the registered names, already public via `/schema`.
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
