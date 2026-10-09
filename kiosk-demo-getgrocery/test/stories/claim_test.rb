# frozen_string_literal: true

require "test_helper"

class ClaimStory < StoryTest
  HANA = "00000000-0000-0000-0000-000000000042"
  HANAS_CARD = "cus_getgrocery_saved_card"

  setup do
    @provider = Kiosk.configuration.payment_provider
    without_test_card = Kiosk::PaymentProviders::Stripe.new(api_key: ENV.fetch("STRIPE_SECRET_KEY"))
    Kiosk.configuration.payment_provider = @provider.over(without_test_card)
    Kiosk::PaymentProviders::Stripe::CustomerRecord.create!(user_id: HANA, customer_id: HANAS_CARD)
  end

  teardown { Kiosk.configuration.payment_provider = @provider }

  test "an assistant that started on its own is linked to Hana and pays with her saved card" do
    standalone = a_shopper
    left_behind = standalone.orders("banana")
    assert_equal "setup_required", standalone.sets_up_payment["status"]

    link = standalone.asks_to_be_linked(client_id: "getgrocery-claim")
    a_person(email: "hana@example.com", password: "getgrocery-demo-password").approves(link["user_code"])
    hanas = standalone.collects(link)

    assert_equal HANA, hanas.account
    assert_empty hanas.orders_placed
    assert_equal standalone.principal.user_id, Order.find(left_behind["order_id"]).user_id

    assert_equal "ready", hanas.sets_up_payment["status"]
    groceries = hanas.orders("banana")
    assert hanas.pays_for(groceries).ok?
    assert_equal [groceries["order_id"]], hanas.orders_placed.pluck("order_id")
    assert_equal [[HANA, standalone.principal.agent_id]], Kiosk::Settlement.pluck(:user_id, :agent_id)
  end
end
