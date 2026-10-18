# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

require_relative '../config/environment'
require 'kiosk/test_helpers/small_equihash'
require 'rails/test_help'
require 'kiosk/test_helpers/conformance/in_process_origin'
require 'kiosk/test_helpers/conformance/minitest'
require 'kiosk/story_test'
require 'kiosk/test_helpers/stripe_mock'

# The conformance matchers read this origin from the handler registry, the
# router and a GUC-scoped session, as the running server does.
Kiosk::TestHelpers::Conformance.origin = Kiosk::TestHelpers::Conformance::InProcessOrigin.new

module ActiveSupport
  class TestCase
    include Kiosk::TestHelpers::Conformance::Assertions

    def kiosk_origin = Kiosk::TestHelpers::Conformance.require_origin!

    # A refusal carries the wire's own `code`; two of this origin's refusals share 403.
    def assert_kiosk_refused(&)
      error = assert_raises(StandardError, &)
      assert_respond_to error, :code, "a refusal must carry the wire's own code (got #{error.class})"
      error
    end
  end
end

# A shopper's AI assistant: browses the catalog, picks a delivery window,
# orders, pays, and moves a delivery.
class Shopper < Kiosk::TestHelpers::Customer
  HOME = '42 Camden Street, Dublin 2'

  def browses(**) = asks(:catalog, **)
  def delivery_windows(address: HOME, **) = asks(:delivery_slots, delivery_address: address, **)
  def orders_placed = asks(:my_orders).rows

  def orders(*skus, address: HOME, slot_at: window_start(1, Date.current + 1, address), **extra)
    does(:create_order, items: skus.map { { sku: it, qty: 1 } }, slot_at:, delivery_address: address, **extra)
  end

  def pays_for(order) = pays_cart(order['cart'], scope: 'grocery')

  def moves(order, to_window:, on: Date.current + 1)
    does(:reschedule_delivery, order_id: order['order_id'], slot_at: window_start(to_window, on, HOME))
  end

  # The start of the window-th window (1-based) on `on`, as delivery_slots publishes it.
  def window_start(window, on, address) = DeliverySlots.starts(on, DeliverySlots.zone_at(address))[window - 1].iso8601
end

class StoryTest < Kiosk::StoryTest
  setup { Kiosk::TestHelpers::StripeMock.start }

  def a_shopper = a_customer(as: Shopper)
end
