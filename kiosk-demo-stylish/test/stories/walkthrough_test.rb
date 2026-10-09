# frozen_string_literal: true

require "test_helper"

class WalkthroughStory < StoryTest
  test "the bin/demo tour of a running salon books Alice one appointment" do
    assert system({ "SERVER_URL" => live_url }, "bin/demo", chdir: Rails.root, out: File::NULL), "bin/demo failed"
    assert_equal [account_of(:alice)], Appointment.pluck(:user_id)
  end
end
