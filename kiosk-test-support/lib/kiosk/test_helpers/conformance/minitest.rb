# frozen_string_literal: true

require "minitest/assertions"

require "kiosk/test_helpers/conformance"

module Kiosk
  module TestHelpers
    module Conformance
      # Minitest assertions for the four conformance checks.
      #
      # Required by name — `require "kiosk/test_helpers/conformance/minitest"` —
      # and never by `require "kiosk/test_helpers"`, which is what lets this gem
      # depend on no test framework while shipping wiring for two.
      #
      #   class KioskConformanceTest < ActiveSupport::TestCase
      #     include Kiosk::TestHelpers::Conformance::Assertions
      #
      #     def test_every_declared_verb_is_routed
      #       assert_kiosk_verbs_routed
      #     end
      #
      #     def test_catalog_answers_what_it_publishes
      #       assert_kiosk_answer_matches_declared_schema :catalog
      #     end
      #
      #     def test_my_orders_is_scoped_to_the_caller
      #       assert_kiosk_scoped_to_principal :my_orders, as: alice, and_not: bob
      #     end
      #   end
      #
      # Every assertion returns its {Outcome}, so a test that wants to look at
      # the facts rather than the sentence can.
      module Assertions
        # Every declared verb has a route, reaching the wire under its own name,
        # with the method its kind requires.
        def assert_kiosk_verbs_routed(message = nil, origin: nil)
          kiosk_conformance!(Conformance.routes(kiosk_conformance_origin(origin)), message)
        end

        # The verb executes as this principal with these arguments. `params:`
        # defaults to the verb's own `example_params`.
        def assert_kiosk_verb_executes(name, params: Checks::EXAMPLE, as: nil,
                                       message: nil, origin: nil)
          kiosk_conformance!(
            Checks.executes(kiosk_conformance_origin(origin), name, params: params, as: as),
            message,
          )
        end

        # The verb's answer satisfies the `output_schema` it publishes — and its
        # arguments satisfy the `input_schema`, checked first and reported
        # separately.
        def assert_kiosk_answer_matches_declared_schema(name, params: Checks::EXAMPLE, as: nil,
                                                        message: nil, origin: nil)
          kiosk_conformance!(
            Checks.declared_shape(kiosk_conformance_origin(origin), name, params: params, as: as),
            message,
          )
        end

        # No row the `as:` principal sees reaches the `and_not:` principal — and
        # the `as:` principal must see something, or the assertion fails for
        # having no positive control.
        def assert_kiosk_scoped_to_principal(name, as:, and_not:, params: Checks::EXAMPLE,
                                             message: nil, origin: nil)
          kiosk_conformance!(
            Checks.principal_scope(kiosk_conformance_origin(origin), name,
                                   as: as, and_not: and_not, params: params),
            message,
          )
        end

        private

        # One assertion per check, so a passing check is COUNTED. `flunk` alone
        # would leave a green run reporting fewer assertions than it made, and
        # an assertion count is one of the few things that shows a suite has
        # stopped running.
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
