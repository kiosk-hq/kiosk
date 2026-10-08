# frozen_string_literal: true

require "test_helper"

class BookAppointmentTest < ActiveSupport::TestCase
  PARIS   = SalonClock.default_zone
  TORONTO = Time.find_zone!("America/Toronto")

  setup do
    @visitor = User.create!(email: "visitor@example.test", password: "test-fixture-password")
    @paris   = Salon.create!(name: "Paris salon")
    @toronto = Salon.create!(name: "Toronto salon", timezone: TORONTO.name)
    @colour  = Service.create!(name: "Colour", price_cents: 9000)
  end

  test "a slot without an offset names no instant and is refused" do
    refusal = assert_kiosk_refused { book(slot: "2026-12-14T14:00:00") }
    assert_includes refusal.message, "slot"
    assert_equal 0, Appointment.count
  end

  test "a slot that is not a timestamp is refused" do
    ["banana", "12345", "2026-12-14", "2026-13-01T14:00:00+01:00"].each do |bad|
      assert_kiosk_refused { book(slot: bad) }
    end
    assert_equal 0, Appointment.count
  end

  test "one instant in any spelling is one booking, answered on the salon's clock" do
    travel_to Time.utc(2026, 9, 1) do
      ["2026-09-14T14:00:00+02:00", "2026-09-14T12:00:00Z", "2026-09-15T01:00:00+13:00"].each do |slot|
        assert_equal "2026-09-14T14:00:00+02:00", book(slot: slot)["slot"]
        assert_equal "2026-09-14T08:00:00-04:00", book(slot: slot, salon: @toronto)["slot"]
      end
      assert_equal [Time.utc(2026, 9, 14, 12)], Appointment.distinct.pluck(:slot)
    end
  end

  test "the salon's zone is a real IANA zone, so winter is CET" do
    travel_to Time.utc(2026, 1, 1) do
      assert_equal "2026-01-14T14:00:00+01:00", book(slot: "2026-01-14T13:00:00Z")["slot"]
    end
  end

  test "the answer names the salon's zone and captures the service price" do
    answer = book(slot: BookAppointmentOperation.example_slot, salon: @toronto, service: @colour)

    assert_equal "America/Toronto", answer["timezone"]
    assert_equal ["Colour", 9000, "€90"], answer.values_at("service", "price_cents", "price_eur")
    assert_equal 9000, Appointment.sole.price_cents
  end

  test "the published example is 14:00 on the origin's clock, a week ahead" do
    example = Time.iso8601(BookAppointmentOperation.example_slot)
    assert_equal 14, example.in_time_zone(PARIS).hour
    assert_equal PARIS.now.advance(days: 7).utc_offset, example.utc_offset
    assert_operator example, :>, Time.current
  end

  test "a slot that has passed is refused on the salon's clock" do
    refusal = assert_kiosk_refused { book(slot: "2020-01-14T13:00:00Z", salon: @toronto) }
    assert_includes refusal.message, "2020-01-14T08:00:00-05:00"
    assert_includes refusal.message, "already passed"
  end

  test "an unknown salon or service is refused by name" do
    assert_includes assert_kiosk_refused { book(salon_id: 999_999) }.message, "unknown salon_id 999999"
    assert_includes assert_kiosk_refused { book(service_id: 999_999) }.message, "#{@colour.id} (Colour)"
    assert_equal 0, Appointment.count
  end

  private

  def book(slot: BookAppointmentOperation.example_slot, salon: @paris, salon_id: salon.id,
           service: nil, service_id: service&.id)
    params = { salon_id: salon_id, slot: slot, service_id: service_id }.compact
    kiosk_origin.call("book_appointment", kind: :action, params: params, as: @visitor)
  end
end
