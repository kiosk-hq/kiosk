# frozen_string_literal: true

# `bin/rails test` for this demo, which is what an adopting operator reaches for
# first. The Kiosk pieces are three lines and they are the whole of the wiring:
# require the engine-backed ORIGIN, require the MINITEST adapter, and hand the
# one to the other.
#
# The origin is what answers the four questions the conformance checks ask —
# which verbs does this app declare, what does its router say about them, what
# does a verb answer as a given principal, and does that answer satisfy the
# schema the verb published. It reads all four from the same places the running
# server does: the registry `config/initializers/kiosk.rb` populated through
# `c.handlers`, `Rails.application.routes`, the registered handler under a
# GUC-scoped session, and the engine's own response validator.
#
# The RSpec spelling is the same three lines with `conformance/rspec` in place
# of `conformance/minitest` — kiosk-demo-hoteling is the worked example of that
# half.

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

require "kiosk/server/conformance_origin"
require "kiosk/test_helpers/conformance/minitest"

Kiosk::TestHelpers::Conformance.origin = Kiosk::Server::ConformanceOrigin.new

module ActiveSupport
  class TestCase
    # Not parallelised. Each conformance call opens its own GUC-scoped
    # transaction on the connection the example is already using, and forked
    # workers would each need their own seeded database for a scoping assertion
    # that is about two principals sharing one.
    include Kiosk::TestHelpers::Conformance::Assertions

    # ── What a REGRESSION example needs beside those four matchers ──────────
    #
    # The conformance checks ask whether a verb is reachable and whether its
    # answer has the declared SHAPE. This demo's own examples ask the other
    # question — what a verb actually ANSWERS, and what it wrote while doing it
    # — and they reach a handler through the same origin, so the two kinds of
    # example run against one wiring. Both helpers live here rather than in each
    # example file so that two files cannot come to disagree about how a refusal
    # is recognised.

    # The origin this suite is wired to: the registry, the router, and a
    # GUC-scoped session with the verb's own `input_schema` validated first.
    def kiosk_origin = Kiosk::TestHelpers::Conformance.require_origin!

    # A refusal reaches a caller as the wire's own typed error rather than as a
    # return value, so an example asserts on the RAISE and reads the `code` off
    # it. The CODE and not the status: two of this origin's refusals are both
    # 403, so the status cannot tell them apart.
    def assert_kiosk_refused
      error = assert_raises(StandardError) { yield }
      assert_respond_to error, :code,
                        "a refusal must carry the wire's own code (got #{error.class})"
      error
    end
  end
end
