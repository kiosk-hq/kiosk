# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      HTTP_METHODS = { query: 'GET', action: 'POST' }.freeze

      # The engine's own endpoints, which answer the verbs the engine serves.
      WIRE_ENDPOINTS = {
        query: 'kiosk/server/verb#show',
        action: 'kiosk/server/verb#create'
      }.freeze

      # One declared verb, as an origin's descriptor presents it to the checks.
      # `endpoint` is the `controller#action` that answers it.
      Verb = Data.define(:name, :kind, :reach, :input_schema, :output_schema, :example_params, :endpoint) do
        def initialize(name:, kind:, reach: 'principal', endpoint: nil, **schemas)
          kind = kind.to_sym
          raise ArgumentError, "kind must be :query or :action, got #{kind.inspect}" unless HTTP_METHODS.key?(kind)

          super(name: name.to_s, kind: kind, reach: (reach || 'principal').to_s,
                endpoint: endpoint || WIRE_ENDPOINTS.fetch(kind),
                input_schema: nil, output_schema: nil, example_params: nil, **schemas)
        end

        def query? = kind == :query

        def http_method = HTTP_METHODS.fetch(kind)

        def other_http_method = HTTP_METHODS.fetch(query? ? :action : :query)

        def to_s = "#{kind} #{name.inspect}"
      end
    end
  end
end
