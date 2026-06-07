# frozen_string_literal: true

require "test_helper"

class KioskRLSMinitestTest < Minitest::Test
  def test_version_defined
    refute_nil Kiosk::RLSMinitest::VERSION
  end

  def test_require_loads_journey_module
    assert defined?(Kiosk::TestHelpers::Journey)
  end

  def test_require_loads_assertions_module
    assert defined?(Kiosk::RLSMinitest::Assertions)
  end
end
