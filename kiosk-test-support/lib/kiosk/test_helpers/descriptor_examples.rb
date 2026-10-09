# frozen_string_literal: true

require "json_schemer"

module Kiosk
  module TestHelpers
    # The examples a served /kiosk/schema publishes, each beside the schema it
    # must satisfy: `example_params` against `input_schema`, `example_row`
    # against one row of `output_schema`.
    module DescriptorExamples
      PAGING = %w[limit cursor].freeze

      Example = Data.define(:verb, :slot, :value, :schema) do
        def violation
          return "#{verb}: #{slot} has no schema to satisfy" unless schema

          errors = JSONSchemer.schema(schema, meta_schema: "https://json-schema.org/draft/2020-12/schema")
                              .validate(value).first(3).map { _1["error"] }
          "#{verb}: #{slot} violates its schema — #{errors.join("; ")}" if errors.any?
        end
      end

      def self.of(document)
        (Array(document["queries"]) + Array(document["actions"])).flat_map do |descriptor|
          [params(descriptor), row(descriptor)].compact
        end
      end

      def self.params(descriptor)
        return unless descriptor.key?("example_params")

        declared = descriptor["input_schema"]
        undeclared = PAGING - (declared&.dig("properties")&.keys || [])
        Example.new(descriptor["name"], "example_params", descriptor["example_params"].except(*undeclared), declared)
      end

      def self.row(descriptor)
        return unless descriptor.key?("example_row")

        declared = descriptor["output_schema"]
        if declared&.dig("type") == "array" && declared["items"].is_a?(Hash)
          declared = declared.except("type", "description", "items").merge(declared["items"])
        end
        Example.new(descriptor["name"], "example_row", descriptor["example_row"], declared)
      end
    end
  end
end
