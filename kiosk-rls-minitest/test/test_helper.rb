# frozen_string_literal: true

require 'minitest/autorun'
require 'kiosk/rls_minitest'

# Minimal stand-in for an ActiveRecord user row.
FakeUser = Struct.new(:id, :role)

module Minitest
  class Test
    def setup
      Kiosk.reset!
      Kiosk::TestHelpers.reset!
      Kiosk::TestHelpers.executor = Kiosk::TestHelpers::NullExecutor.new
    end
  end
end
