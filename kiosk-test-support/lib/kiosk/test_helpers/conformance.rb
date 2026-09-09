# frozen_string_literal: true

require "kiosk/test_helpers/errors"
require "kiosk/test_helpers/conformance/outcome"
require "kiosk/test_helpers/conformance/verb"
require "kiosk/test_helpers/conformance/checks"
require "kiosk/test_helpers/conformance/null_origin"

module Kiosk
  module TestHelpers
    # THE OPERATOR'S CONFORMANCE SURFACE — four checks an origin can run against
    # itself, for the four properties the protocol makes normative of it:
    #
    #   1. its ROUTES resolve;
    #   2. a VERB EXECUTES;
    #   3. a QUERY ANSWERS THE SHAPE IT DECLARED;
    #   4. its DATA ACCESS IS SCOPED to the authenticated principal.
    #
    # Those four are what an origin is asked to conform to, so having no way to
    # run them means an operator cannot demonstrate conformance to the document
    # they are handed. This namespace is that way, and it is deliberately small:
    # four assertions, no runner, no report, no verdict file.
    #
    # ── How it is wired ─────────────────────────────────────────────────────
    #
    # The checks are pure functions of an ORIGIN, and this module is inert until
    # one is set — the same shape as `Kiosk::TestHelpers.executor=`, and for the
    # same reason: the code that knows how to read a Rails route table and
    # dispatch a registered handler belongs to the engine, and this gem depends
    # on neither Rails nor the engine.
    #
    #   # spec/spec_helper.rb (RSpec) or test/test_helper.rb (Minitest)
    #   require "kiosk/server/conformance_origin"
    #   Kiosk::TestHelpers::Conformance.origin = Kiosk::Server::ConformanceOrigin.new
    #
    # Then require ONE adapter — never both, and neither by default, so this gem
    # keeps its no-test-framework-dependency posture:
    #
    #   require "kiosk/test_helpers/conformance/minitest"   # assertions
    #   require "kiosk/test_helpers/conformance/rspec"      # matchers
    #
    # ── What an adopter writes ──────────────────────────────────────────────
    #
    #   # Minitest
    #   assert_kiosk_verbs_routed
    #   assert_kiosk_verb_executes                  :catalog
    #   assert_kiosk_answer_matches_declared_schema :catalog
    #   assert_kiosk_scoped_to_principal            :my_orders, as: alice, and_not: bob
    #
    #   # RSpec
    #   expect(kiosk_origin).to have_a_route_for_every_verb
    #   expect(:catalog).to     execute_as_a_kiosk_verb
    #   expect(:catalog).to     answer_its_declared_schema
    #   expect(:my_orders).to   be_scoped_to_principal(as: alice, and_not: bob)
    #
    # Both spellings take the same keywords, because they are {Checks}'
    # keywords and the adapters forward them unchanged. Both render the same
    # {Outcome#message}, so a fault found in one framework and reproduced in the
    # other reads identically.
    #
    # ── What these checks are NOT ───────────────────────────────────────────
    #
    # They are necessary, not sufficient, and nothing here issues a verdict: no
    # badge, no report artefact, no `--json` summary. They run in-process
    # against the registry the operator's own boot built — there is no HTTP hop,
    # no bearer minting, no proof-of-work and no device grant, because shipping
    # an agent client into every adopter's test suite is a different product.
    # And they say nothing about payment settlement or about row-level security
    # policies: `pay` is not one of the four, and RLS is opt-in while these four
    # properties are not.
    module Conformance
      class << self
        # The active origin — anything answering the contract documented on
        # {NullOrigin}. Defaults to nil; a check then raises
        # {Errors::OriginNotConfigured} with a wiring hint.
        attr_accessor :origin

        # Raise unless an origin is wired. Returns it, for chaining.
        def require_origin!
          origin || raise(Errors::OriginNotConfigured)
        end

        # Drop the configured origin — between-test cleanup.
        def reset!
          @origin = nil
        end

        # ── The four checks, against the configured origin ────────────────
        #
        # These are what the two adapters call. They exist here as well as on
        # {Checks} so that an adopter with an unusual harness — or none — can
        # run a check and read its {Outcome} without an adapter at all.

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
