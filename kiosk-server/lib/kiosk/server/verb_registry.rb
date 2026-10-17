# frozen_string_literal: true

require 'kiosk/server/errors'
require 'kiosk/server/schema_slots'

module Kiosk
  module Server
    # A verb registry: name → handler plus the descriptor an origin publishes.
    # {Queries} and {Actions} are this module plus a `SCOPE`. Verbs are declared
    # through {Kiosk::Handler}; `input_schema` and `output_schema` are required (§8.3).
    module VerbRegistry
      Entry = Data.define(:handler, :reach, :description, :input_schema, :output_schema,
                          :example_params, :example_row)

      class << self
        # Undeclared optional keys are omitted rather than null.
        def add_declared_slots(descriptor, found)
          descriptor[:input_schema]   = found.input_schema   unless found.input_schema.nil?
          descriptor[:output_schema]  = found.output_schema  unless found.output_schema.nil?
          descriptor[:example_params] = found.example_params unless found.example_params.nil?
          descriptor[:example_row]    = found.example_row    unless found.example_row.nil?
          descriptor
        end
      end

      # @api private — the {HandlerMixin} is the only caller.
      # `slots`: any of {SchemaSlots::RESOLVABLE_SLOTS}; an undeclared one is nil.
      def declare(name, handler, reach: HandlerMixin::DEFAULT_REACH, description: nil, **slots)
        slots = SchemaSlots::RESOLVABLE_SLOTS.to_h { |slot| [slot, nil] }.merge(slots)
        entry = Entry.new(handler: handler, reach: reach, description: description, **slots)
        SchemaSlots.note_declaration(slots)
        registry[name.to_s] = entry
      end

      def fetch(name)
        entry(name).handler
      end

      def describe(name)
        found = entry(name)
        SchemaSlots.descriptor(self::SCOPE, name, found) do
          descriptor = { name: name.to_s, description: found.description, reach: found.reach.to_s }
          VerbRegistry.add_declared_slots(descriptor, found)
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
            hint: Errors.unknown_name_hint(name, self::SCOPE.to_s, registry.keys.sort)
          )
        end
      end

      def registry
        @registry ||= {}
      end
    end
  end
end
