# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

require "kiosk/server/conformance_origin"
require "kiosk/test_helpers/conformance/minitest"

Kiosk::TestHelpers::Conformance.origin = Kiosk::Server::ConformanceOrigin.new

module ActiveSupport
  class TestCase
    include Kiosk::TestHelpers::Conformance::Assertions

    # The registry, the router, and a GUC-scoped session with the verb's own
    # `input_schema` validated first — what the wire runs.
    def kiosk_origin = Kiosk::TestHelpers::Conformance.require_origin!

    def assert_kiosk_refused(&)
      error = assert_raises(Kiosk::Server::Errors::Base, &)
      assert_equal "bad_request", error.code
      error
    end
  end
end
