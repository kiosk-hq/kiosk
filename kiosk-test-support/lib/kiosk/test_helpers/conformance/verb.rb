# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      # The two kinds, and the HTTP method each is reached by. A query is a read
      # on GET, an action is a write on POST; the method follows the kind, which
      # is the property the route check holds.
      #
      # Declared in the MODULE body rather than inside the Data block below: a
      # constant written in a block is defined in that block's lexical scope,
      # which is this module either way, so writing it here is what the reader
      # sees and what `Verb::METHODS` would NOT have found.
      HTTP_METHODS = { query: "GET", action: "POST" }.freeze

      # The wire controller action each kind dispatches to. A route that reaches
      # anything else has bypassed the wire.
      WIRE_ENDPOINTS = {
        query:  "kiosk/server/verb#show",
        action: "kiosk/server/verb#create",
      }.freeze

      # One declared verb, as the checks need to see it.
      #
      # This is a VIEW of a descriptor, not a second copy of one: an origin
      # builds it from whatever the host actually has (on a Rails origin, the
      # engine's own `Queries.catalog` / `Actions.catalog`). Nothing here is a
      # place to record a verb — a verb is declared by `include Kiosk::Handler`
      # in a controller the operator owns, and there is exactly one way in.
      #
      # `reach` is a String and defaults to "principal", which is what a
      # declaration that says nothing means. It is carried rather than looked up
      # so the scoping check can refuse to run on a verb whose declared reach
      # makes cross-principal disjointness the wrong assertion.
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

        def query?  = kind == :query
        def action? = kind == :action

        # The HTTP method this verb's kind requires.
        def http_method = HTTP_METHODS.fetch(kind)

        # The method it must NOT also answer on. Asked for by name so the route
        # check can assert the negative half without knowing the table.
        def other_http_method = HTTP_METHODS.fetch(query? ? :action : :query)

        def endpoint = WIRE_ENDPOINTS.fetch(kind)

        def to_s = "#{kind} #{name.inspect}"
      end
    end
  end
end
