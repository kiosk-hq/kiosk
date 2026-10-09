# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
ENV["KIOSK_TEST_AUTOCARD"] = "1"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/server/conformance_origin"
require "kiosk/test_helpers/conformance/minitest"
require "kiosk/story_test"
require "kiosk/test_helpers/stripe_mock"

# The conformance matchers read this origin from the handler registry, the
# router and a GUC-scoped session, as the running server does.
Kiosk::TestHelpers::Conformance.origin = Kiosk::Server::ConformanceOrigin.new

module ActiveSupport
  class TestCase
    include Kiosk::TestHelpers::Conformance::Assertions

    def kiosk_origin = Kiosk::TestHelpers::Conformance.require_origin!

    # A refusal carries the wire's own `code`; two of this origin's refusals share 403.
    def assert_kiosk_refused
      error = assert_raises(StandardError) { yield }
      assert_respond_to error, :code, "a refusal must carry the wire's own code (got #{error.class})"
      error
    end
  end
end

# A shopper's AI assistant: browses the catalog, picks a delivery window,
# orders, pays, and moves a delivery.
class Shopper < Kiosk::TestHelpers::Customer
  HOME = "42 Camden Street, Dublin 2"

  def browses(**) = asks(:catalog, **)
  def delivery_windows(address: HOME, **) = asks(:delivery_slots, delivery_address: address, **)
  def orders_placed = asks(:my_orders).rows

  def orders(*skus, window: 1, on: Date.current + 1, address: HOME, **extra)
    does(:create_order, items: skus.map { { sku: _1, qty: 1 } }, delivery_slot_id: window,
                        delivery_date: on.to_s, delivery_address: address, **extra)
      .tap { (@baskets ||= {})[_1["order_id"]] = skus }
  end

  # Signs a cart that names the order and every item in it at the catalog price.
  def pays_for(order)
    lines = @baskets.fetch(order["order_id"]).map { { sku: _1, qty: 1, price_cents: Product.find_by!(sku: _1).price_cents } }
    pays(total: order["total_cents"], scope: "grocery", line_items: [{ order_id: order["order_id"] }] + lines)
  end

  def moves(order, to_window:, on: Date.current + 1)
    does(:reschedule_delivery, order_id: order["order_id"], delivery_slot_id: to_window, delivery_date: on.to_s)
  end
end

class StoryTest < Kiosk::StoryTest
  setup { Stripe.api_base = Kiosk::TestHelpers::StripeMock.start }

  def a_shopper = a_customer(as: Shopper)
end
