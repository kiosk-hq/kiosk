# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
ENV["KIOSK_TEST_AUTOCARD"] = "1"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/server/conformance_origin"
require "kiosk/test_helpers/conformance/minitest"
require "kiosk/test_helpers/live_server"
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

# Drives this origin over HTTP as an assistant does.
class WireTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::LiveServer

  DELIVERY_ADDRESS = "42 Camden Street, Dublin 2"

  setup { Stripe.api_base = Kiosk::TestHelpers::StripeMock.start }

  def delivery_date = (Date.current + 1).iso8601

  def catalog(shopper) = assistant.query(shopper, name: "catalog").body.index_by { _1["sku"] }

  def create_order(shopper, skus, delivery_slot_id: 1, **args)
    assistant.run(shopper, name: "create_order", items: skus.map { { sku: _1, qty: 1 } },
                        delivery_slot_id:, delivery_date:, delivery_address: DELIVERY_ADDRESS, **args)
  end

  def order(shopper, *skus)
    placed = create_order(shopper, skus)
    assert_equal 200, placed.status, placed.body
    placed.body.merge("skus" => skus)
  end

  # The cart mirrors the order: its id, then every item at the catalog price.
  def pay(shopper, order)
    now   = Time.now.to_i
    total = order.fetch("total_cents")
    lines = order.fetch("skus").map { { sku: _1, qty: 1, price_cents: Product.find_by!(sku: _1).price_cents } }
    mandate = { user_id: shopper.user_id, agent_id: shopper.agent_id, iss: live_url, currency: "eur",
                iat: now, exp: now + 600 }
    intent = mandate.merge(id: SecureRandom.uuid, scope: "grocery", cap_amount_cents: total)
    cart   = mandate.merge(id: SecureRandom.uuid, intent_mandate_id: intent[:id], total_amount_cents: total,
                           line_items: [{ order_id: order.fetch("order_id") }] + lines)
    assistant.pay(shopper, intent:, cart:)
  end

  def my_order_ids(shopper) = assistant.query(shopper, name: "my_orders").body.map { _1["order_id"] }
end
