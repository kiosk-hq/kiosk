# frozen_string_literal: true

require "test_helper"

class RegistrationStory < StoryTest
  def arrives_without_paying = Kiosk::TestHelpers::Answer.new(assistant.register_raw(pow: :skip))

  test "a new assistant pays a proof-of-work toll to register, then finds the salon" do
    unpaid = arrives_without_paying
    assert unpaid.refused?(:pow_required), unpaid
    assert_equal 1, unpaid["challenges"].size

    client = a_customer(as: Client)
    assert_equal ["Combette on Park"], client.salons.pluck("name")
  end
end
