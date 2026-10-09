# frozen_string_literal: true

require "test_helper"

# An assistant inherits its human's role from the sign-in it was linked over.
class RolesTest < WireTest
  def calendar(assistant)
    answer = client.query(assistant, name: "salon_calendar")
    assert_equal 200, answer.status, answer.body
    answer.body
  end

  def price(service) = { service_id: Service.find_by!(name: service).id }

  test "the owner's assistant sees the whole book and a forecast of its prices" do
    alices = book(bind("alice@example.com"), **price("Colour"))["appointment_id"]
    bobs   = book(bind("bob@example.com"), **price("Cut"))["appointment_id"]
    owner  = bind("owner@combette.example")
    assert_equal "owner", claims(owner)["role"]

    *bookings, forecast = calendar(owner)
    assert_equal [alices, bobs].sort, bookings.map { _1["id"] }.sort
    assert_equal ["forecast", 2, 12_500], forecast.values_at("summary", "bookings", "forecast_cents")
  end

  test "a customer's assistant sees only its own bookings and no forecast" do
    alice  = bind("alice@example.com")
    alices = book(alice)["appointment_id"]
    book(bind("bob@example.com"))
    assert_equal "customer", claims(alice)["role"]

    assert_equal [[alices, "booking"]], calendar(alice).map { _1.values_at("id", "kind") }
  end
end
