# frozen_string_literal: true

# Activates a paid reservation of a licence-required motorcycle, for a rider
# attested `age_over_18` and `licence_a`.
class RentMotorcycleOperation
  def self.call(reservation_id:)
    Kiosk::Server::Kyc.require!
    reservation = Rental.own_reservation!(reservation_id)
    unless reservation.scooter.licence_required?
      raise Kiosk::Server::Errors::BadRequest,
            "#{reservation.scooter.code} is not a licence-required motorcycle — use start_rental " \
            "for licence-free vehicles"
    end
    Rental.require_paid!(reservation)
    Rental.activate!(reservation)
  end
end
