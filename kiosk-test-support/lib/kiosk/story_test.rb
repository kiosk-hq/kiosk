# frozen_string_literal: true

require 'active_support/test_case'
require 'kiosk/test_helpers/story'

module Kiosk
  # Minitest's form of Kiosk::TestHelpers::Story; RSpec includes the module.
  class StoryTest < ActiveSupport::TestCase
    include TestHelpers::Story

    # Asserts the protocol refused `response` with `code`.
    def assert_refused(response, code)
      assert response.refused?(code), "expected a #{code} refusal, got #{response}"
    end
  end
end
