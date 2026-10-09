# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      HTTP_METHODS = { query: "GET", action: "POST" }.freeze

      WIRE_ENDPOINTS = {
        query:  "kiosk/server/verb#show",
        action: "kiosk/server/verb#create",
      }.freeze

      # One declared verb, as an origin's descriptor presents it to the checks.
      Verb = Data.define(:name, :kind, :reach, :input_schema, :output_schema, :example_params) do
        def initialize(name:, kind:, reach: "principal", input_schema: nil,
                       output_schema: nil, example_params: nil)
          kind = kind.to_sym
          unless HTTP_METHODS.key?(kind)
            raise ArgumentError, "kind must be :query or :action, got #{kind.inspect}"
          end

          super(name: name.to_s, kind: kind, reach: (reach || "principal").to_s,
                input_schema: input_schema, output_schema: output_schema,
                example_params: example_params)
        end

        def query? = kind == :query

        def http_method = HTTP_METHODS.fetch(kind)

        def other_http_method = HTTP_METHODS.fetch(query? ? :action : :query)

        def endpoint = WIRE_ENDPOINTS.fetch(kind)

        def to_s = "#{kind} #{name.inspect}"
      end
    end
  end
end
