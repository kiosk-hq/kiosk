# frozen_string_literal: true

require "test_helper"

# An order left `paying` by a crash between the capture and the paid-flip.
class StuckPayingTest < ActiveSupport::TestCase
  IntentMandate = Class.new(ActiveRecord::Base) { self.table_name = "kiosk.intent_mandates" }

  class ScriptedProcessor
    attr_reader :asked

    def initialize(answers) = (@answers, @asked = answers, [])

    def outcome(cart_mandate_id:, amount_cents:, currency:)
      @asked << [cart_mandate_id, amount_cents, currency]
      @answers.fetch(cart_mandate_id)
    end
  end

  setup do
    Stripe.api_base = Kiosk::Redteam::StripeMock.start
    @shopper = User.create!
    @banana  = Product.create!(sku: "banana", name: "Banana", price_cents: 149, stock: 80)
  end

  # A claimed order whose cart mandate was recorded, as the pay path leaves it.
  def stranded(mandate_id, claimed: 1.hour.ago)
    order = Order.create!(user: @shopper, status: "paying", total_cents: 149, slot_at: 1.day.from_now,
                          address: "42 Camden Street, Dublin 2", timezone: DeliverySlots::DEFAULT_ZONE_NAME)
    order.order_items.create!(product: @banana, qty: 1)
    mandate = { user_id: @shopper.id, agent_id: SecureRandom.uuid, issuer: "https://getgrocery.test", currency: "eur",
                expires_at: 1.hour.from_now, raw_jws: "jws" }
    intent = IntentMandate.create!(mandate.merge(mandate_id: "intent-#{mandate_id}", scope: "grocery", cap_amount_cents: 149))
    cart   = Kiosk::CartMandate.create!(mandate.merge(mandate_id:, intent_mandate_id: intent.id, total_amount_cents: 149,
                                                      line_items: [{ order_id: order.id }]))
    order.update_columns(updated_at: claimed)
    [order, cart]
  end

  def settle(cart) = Kiosk::Settlement.create!(cart_mandate: cart, user_id: cart.user_id, agent_id: cart.agent_id, issuer: cart.issuer,
                                               psp_reference: "pi_settled", settled_amount_cents: 149, currency: "eur", settled_at: Time.current)

  def sweep(lookup) = StuckPaying.reconcile!(lookup:, older_than_seconds: 600)

  test "the sweep acts on each answer the processor can give, and asks only when it has no receipt" do
    charged,  = stranded("cart-charged")
    declined, = stranded("cart-declined")
    silent,   = stranded("cart-silent")
    settled, cart = stranded("cart-settled")
    settle(cart)
    young, = stranded("cart-young", claimed: 1.second.ago)
    head = Kiosk.configuration.event_store.head
    processor = ScriptedProcessor.new("cart-charged" => :paid, "cart-declined" => :not_charged, "cart-silent" => :unknown)

    result = sweep(processor)

    assert_equal [charged.id, settled.id].sort, result[:healed].sort
    assert_equal [declined.id], result[:released]
    assert_equal [{ order_id: silent.id, cart_mandate_ids: ["cart-silent"] }], result[:unresolved].map { _1.except(:claimed_at) }
    assert_equal %w[paid created paying paid paying], [charged, declined, silent, settled, young].map { _1.reload.status }
    assert_equal [["cart-charged", 149, "eur"], ["cart-declined", 149, "eur"], ["cart-silent", 149, "eur"]], processor.asked.sort

    healed = Kiosk.configuration.event_store.since(@shopper.id, head)
    assert_equal [charged.id, settled.id].sort, healed.map { _1["subject"] }.sort
    assert_empty Kiosk::Redteam::EventStream.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), healed)
  end

  test "a retried pay on an order with a receipt heals it instead of charging again" do
    order, cart = stranded("cart-charged")
    settle(cart)
    retry_cart = Kiosk::Mandate::CartMandate.new(
      id: "cart-retry", intent_mandate_id: "intent-retry", user_id: @shopper.id, agent_id: cart.agent_id,
      issuer: cart.issuer, line_items: [{ "order_id" => order.id }, { "sku" => "banana", "qty" => 1, "price_cents" => 149 }],
      total_amount_cents: 149, currency: "eur", expires_at: nil, created_at: nil, raw_jws: "cart",
    )
    psp = Object.new # a second charge would call #capture on it

    error = assert_raises(Kiosk::Server::Errors::Forbidden) { Kiosk.configuration.payment_provider.over(psp).capture(retry_cart) }
    assert_includes error.message, "already paid"
    assert_equal "paid", order.reload.status
  end

  test "stripe-mock's canned intent names no cart of ours, so the claim is kept" do
    order, = stranded("cart-#{SecureRandom.uuid}")
    lookup = Kiosk::PaymentProviders::Stripe::ChargeLookup.new

    assert_includes Kiosk::PaymentProviders::Stripe::ChargeLookup::NOT_CHARGED,
                    Stripe::PaymentIntent.search(query: "metadata['cart_mandate_id']:'cart-x'").data.first.status
    result = sweep(lookup)
    assert_equal [[order.id], []], [result[:unresolved].map { _1[:order_id] }, result[:released]]
    assert_equal "paying", order.reload.status
  end
end
