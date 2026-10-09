# frozen_string_literal: true

require "kiosk/test_helpers/story"

# RSpec's form of Kiosk::StoryTest: every `type: :story` group tells a story.
RSpec.configure { _1.include Kiosk::TestHelpers::Story, type: :story }
