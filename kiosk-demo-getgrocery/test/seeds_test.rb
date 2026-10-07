# frozen_string_literal: true

require "test_helper"

# The seeded account holder's saved card is a stripe-mock fixture.
class SeedsTest < ActiveSupport::TestCase
  HUMAN_ID = "00000000-0000-0000-0000-000000000042"
  FIXTURE  = "cus_getgrocery_saved_card"

  def seed_with(mock_url)
    config   = Rails.configuration.x.kiosk
    previous = config.stripe_mock_url
    config.stripe_mock_url = mock_url
    capture_io { Rails.application.load_seed }
  ensure
    config.stripe_mock_url = previous
  end

  test "against stripe-mock the account holder has the fixture card" do
    seed_with("http://127.0.0.1:12111")
    assert_equal FIXTURE, StripeCustomer.find_by(user_id: HUMAN_ID)&.customer_id
  end

  test "against real Stripe the fixture card is not mapped" do
    seed_with(nil)
    assert_nil StripeCustomer.find_by(user_id: HUMAN_ID)
  end
end
