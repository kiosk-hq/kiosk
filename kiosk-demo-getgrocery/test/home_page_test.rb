# frozen_string_literal: true

require 'test_helper'

# The storefront's live activity.
class HomePageTest < ActionDispatch::IntegrationTest
  test 'deliveries scheduled counts every paid order still waiting for the courier' do
    shopper = User.create!(email: 'home@example.test', password: 'conformance-fixture-password')
    [%w[placed unpaid], %w[placed paid], %w[rescheduled paid], %w[delivered paid]].each do |status, payment_status|
      Order.create!(user: shopper, status:, payment_status:, total_cents: 449, slot_at: Time.current,
                    address: '1 Dame Street, Dublin 2', timezone: DeliverySlots::DEFAULT_ZONE_NAME)
    end

    get root_path

    assert_select '.stat', text: /2\s*Deliveries scheduled/
  end

  test 'names the shop GetGrocery, and Start shopping leads to how an assistant shops here' do
    get root_path

    assert_select 'header .logo', 'GetGrocery'
    assert_select 'a.cta[href="#try"]', 'Start shopping'
    assert_select 'section#try', text: /Try it with your own assistant/
  end
end
