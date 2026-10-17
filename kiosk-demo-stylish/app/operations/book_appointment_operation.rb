# frozen_string_literal: true

# Books a salon, optionally one service from its menu, for the customer at the
# price the menu quotes now. Returns the appointment.
class BookAppointmentOperation
  def self.call(customer_id:, salon_id:, slot:, service_id:)
    Appointment.create!(user_id: customer_id, salon_id: salon_id, slot: Time.iso8601(slot), service_id: service_id)
  end

  # A week out at 14:00 on the origin's clock: always in the future, on a round hour.
  def self.example_slot
    SalonClock.default_zone.now.advance(days: 7).change(hour: 14).iso8601
  end
end
