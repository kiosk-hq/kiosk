# frozen_string_literal: true

require "active_support/test_case"
require "kiosk/test_helpers/story"

module Kiosk
  # Minitest's form of Kiosk::TestHelpers::Story; RSpec includes the module.
  class StoryTest < ActiveSupport::TestCase
    include TestHelpers::Story
  end
end
