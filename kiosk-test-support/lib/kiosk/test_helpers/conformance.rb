# frozen_string_literal: true

require "kiosk/test_helpers/errors"
require "kiosk/test_helpers/conformance/outcome"
require "kiosk/test_helpers/conformance/verb"
require "kiosk/test_helpers/conformance/checks"
require "kiosk/test_helpers/conformance/null_origin"

module Kiosk
  module TestHelpers
    # Four checks an origin runs against itself: routes resolve, a verb executes,
    # an answer matches its declared schema, data access is scoped to the principal.
    # Set `Conformance.origin`, then require the minitest or rspec adapter.
    module Conformance
      class << self
        # Anything answering the {NullOrigin} contract.
        attr_accessor :origin

        def require_origin!
          origin || raise(Errors::OriginNotConfigured)
        end

        def reset!
          @origin = nil
        end

        # The four {Checks} against the configured origin, returning an {Outcome}.
        def routes(origin = require_origin!)
          Checks.routes(origin)
        end

        def executes(name, params: Checks::EXAMPLE, as: nil, origin: require_origin!)
          Checks.executes(origin, name, params: params, as: as)
        end

        def declared_shape(name, params: Checks::EXAMPLE, as: nil, origin: require_origin!)
          Checks.declared_shape(origin, name, params: params, as: as)
        end

        def principal_scope(name, as:, and_not:, params: Checks::EXAMPLE, origin: require_origin!)
          Checks.principal_scope(origin, name, as: as, and_not: and_not, params: params)
        end
      end
    end
  end
end
