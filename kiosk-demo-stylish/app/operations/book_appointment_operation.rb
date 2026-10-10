# frozen_string_literal: true

# Books a salon, optionally one service from its menu, for the principal at the
# price the menu quotes now.
class BookAppointmentOperation
  def self.call(principal_id:, salon_id:, slot:, service_id:)
    appointment = Appointment.create!(user_id: principal_id, salon_id: salon_id, slot: Time.iso8601(slot),
                                      service_id: service_id)
    salon   = appointment.salon
    service = appointment.service

    answer = { appointment_id: appointment.id, salon_id: salon.id,
               slot: SalonClock.publish(appointment.slot, salon.zone), timezone: salon.zone.name }
    return answer unless service

    answer.merge(service: service.name, currency: "EUR",
                 price_cents: service.price_cents, price_eur: service.price_eur)
  end

  # A week out at 14:00 on the origin's clock: always in the future, on a round hour.
  def self.example_slot
    SalonClock.default_zone.now.advance(days: 7).change(hour: 14).iso8601
  end
end
