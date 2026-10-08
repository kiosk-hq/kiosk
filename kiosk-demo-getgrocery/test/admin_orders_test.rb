# frozen_string_literal: true

require "test_helper"

# The operator's order list.
class AdminOrdersTest < ActionDispatch::IntegrationTest
  setup do
    @shopper = User.create!(email: "admin@example.test", password: "conformance-fixture-password")
  end

  def order_in(status)
    Order.create!(user: @shopper, status: status, total_cents: 449,
                  slot_at: Time.current, address: "1 Dame Street, Dublin 2",
                  timezone: DeliverySlots::DEFAULT_ZONE_NAME)
  end

  # Both states are reached by the shipped flow and neither is a settlement
  # fact, so a page that read only the settlement would show a delivered basket
  # as merely paid.
  test "an order with the courier, and a delivered one, each wear their own badge" do
    order_in("out_for_delivery")
    order_in("delivered")

    get admin_orders_path

    assert_response :success
    assert_select ".badge-out-for-delivery", text: "OUT FOR DELIVERY", count: 1
    assert_select ".badge-delivered", text: "DELIVERED", count: 1
  end

  test "an order lists its basket alphabetically and masks the address" do
    order = order_in("created")
    { "Pears" => 349, "Apples" => 199 }.each do |name, price_cents|
      product = Product.create!(sku: "admin-#{name}", name: name, price_cents: price_cents)
      order.order_items.create!(product: product, qty: 2)
    end

    get admin_orders_path

    assert_select ".order-id", text: "##{order.id.first(8)}"
    assert_select ".badge-created", text: "CREATED"
    assert_select ".order-meta", text: /Total: €4\.49/
    assert_select ".order-meta", text: /Address: 1 Da\*{16}n 2/
    assert_select ".item .name" do |names|
      assert_equal %w[Apples Pears], names.map(&:text)
    end
    assert_select ".item .price", text: "€1.99"
  end

  test "an empty shop says so" do
    get admin_orders_path

    assert_select "p.empty", text: /No orders yet/
  end
end
