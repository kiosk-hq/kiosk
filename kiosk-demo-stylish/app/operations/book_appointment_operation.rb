# frozen_string_literal: true

# Books a salon, optionally one service from its menu, for the principal at the
# price the menu quotes now. Raises a wire error on a refusal.
class BookAppointmentOperation
  def self.call(principal_id:, salon_id:, slot:, service_id:)
    salon = Salon.find_by(id: salon_id) ||
            refuse("unknown salon_id #{salon_id.inspect} — call the `salons` query for the bookable salons")
    slot_at = Time.iso8601(slot).in_time_zone(salon.zone)
    if slot_at <= Time.current
      refuse "slot #{SalonClock.publish(slot_at, salon.zone)} has already passed — book a time in the future " \
             "(now is #{SalonClock.publish(Time.current, salon.zone)}); this salon does not record appointments in the past"
    end
    service = service_id && (Service.find_by(id: service_id) || refuse_service(service_id))

    appointment = Appointment.create!(user_id: principal_id, salon: salon, slot: slot_at,
                                      service: service, price_cents: service&.price_cents)

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

  def self.refuse_service(service_id)
    menu = Service.order(:id).pluck(:id, :name).map { |id, name| "#{id} (#{name})" }.join(", ")
    refuse "unknown service_id #{service_id.inspect} — bookable services: #{menu}; " \
           "or omit service_id for a bare salon booking"
  end

  def self.refuse(message)
    raise Kiosk::Server::Errors::BadRequest.new(message)
  end
  private_class_method :refuse, :refuse_service
end
