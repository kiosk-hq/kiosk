# frozen_string_literal: true

require 'test_helper'

class KeptAppointmentStory < StoryTest
  test "a client whose appointment time has passed is recorded as a visit, once, worth the service's price" do
    client = a_customer(as: Client)
    service = client.menu.first
    booked = client.books(service['name'], at: 2.days.from_now.change(hour: 11))

    assert_predicate booked, :ok?, booked
    appointment = Appointment.find(booked['appointment_id'])

    AppointmentKeptJob.perform_now(appointment.id)

    assert_empty Kiosk::Visit.all

    travel_to(appointment.slot + 1.minute) { 2.times { AppointmentKeptJob.perform_now(appointment.id) } }

    assert_equal [[client.principal.user_id, service['price_cents']]], Kiosk::Visit.pluck(:user_id, :value_cents)
  end
end
