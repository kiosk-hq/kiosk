# frozen_string_literal: true

require 'kiosk/test_helpers/conformance/outcome'
require 'kiosk/test_helpers/conformance/verb'
require 'kiosk/test_helpers/conformance/checks/helpers'
require 'kiosk/test_helpers/conformance/checks/routes'
require 'kiosk/test_helpers/conformance/checks/executes'
require 'kiosk/test_helpers/conformance/checks/declared_shape'
require 'kiosk/test_helpers/conformance/checks/principal_scope'

module Kiosk
  module TestHelpers
    module Conformance
      # The four conformance checks, as pure functions of an origin returning an
      # {Outcome}; the Minitest and RSpec adapters render its message verbatim.
      module Checks
        module_function

        # Every declared verb is routed under its own name to the action that
        # answers it, GET for a query and POST for an action. No verbs at all fails.
        def routes(origin)
          Routes.call(origin)
        end

        # Called with these arguments as this principal, the verb answers rather than refusing.
        def executes(origin, name, params: EXAMPLE, as: nil)
          Executes.call(origin, name, params: params, as: as)
        end

        # The arguments satisfy the verb's input_schema and its answer satisfies
        # its output_schema; the two failures are reported separately.
        def declared_shape(origin, name, params: EXAMPLE, as: nil)
          DeclaredShape.call(origin, name, params: params, as: as)
        end

        # No row `as:` sees reaches `and_not:`, compared whole-row. An empty first
        # answer fails, because a scoping assertion with no positive control passes
        # on a verb that answers everybody with nothing. A `published` verb fails too.
        def principal_scope(origin, name, as:, and_not:, params: EXAMPLE)
          PrincipalScope.call(origin, name, as: as, and_not: and_not, params: params)
        end
      end
    end
  end
end
