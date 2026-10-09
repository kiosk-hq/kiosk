# frozen_string_literal: true

require "test_helper"

class JoiningStory < StoryTest
  test "an assistant that will not pay the registration toll cannot join, one that does posts at once" do
    unproven = Kiosk::TestHelpers::Answer.new(assistant.register_raw(pow: :skip))
    assert unproven.refused?(:pow_required), unproven
    assert_not_empty unproven["challenges"]

    assert a_seller.posts.ok?
  end

  test "a seller who names a category the board does not have is told which ones exist" do
    refused = a_seller.posts(category: "not-a-real-slug", title: "x", body: "y")
    assert refused.refused?(:bad_request), refused
    Category.pluck(:slug).each { assert_includes refused["detail"], _1 }
  end
end
