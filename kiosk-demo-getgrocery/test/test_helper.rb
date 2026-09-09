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
  end
end
