# frozen_string_literal: true

require "minitest/assertions"

require "kiosk/test_helpers/conformance"

module Kiosk
  module TestHelpers
    module Conformance
      # Minitest assertions for the four conformance checks; required by name only.
      # Each returns its {Outcome}.
      module Assertions
        def assert_kiosk_verbs_routed(message = nil, origin: nil)
          kiosk_conformance!(Conformance.routes(kiosk_conformance_origin(origin)), message)
        end

        def assert_kiosk_verb_executes(name, params: Checks::EXAMPLE, as: nil,
                                       message: nil, origin: nil)
          kiosk_conformance!(
            Checks.executes(kiosk_conformance_origin(origin), name, params: params, as: as),
            message,
          )
        end

        def assert_kiosk_answer_matches_declared_schema(name, params: Checks::EXAMPLE, as: nil,
                                                        message: nil, origin: nil)
          kiosk_conformance!(
            Checks.declared_shape(kiosk_conformance_origin(origin), name, params: params, as: as),
            message,
          )
        end

        def assert_kiosk_scoped_to_principal(name, as:, and_not:, params: Checks::EXAMPLE,
                                             message: nil, origin: nil)
          kiosk_conformance!(
            Checks.principal_scope(kiosk_conformance_origin(origin), name,
                                   as: as, and_not: and_not, params: params),
            message,
          )
        end

        private

        # `assert` rather than `flunk`, so a passing check is counted.
        def kiosk_conformance!(outcome, message)
          assert(outcome.ok?, message || outcome.message)
          outcome
        end

        def kiosk_conformance_origin(explicit)
          explicit || Conformance.require_origin!
        end
      end
    end
  end
end
