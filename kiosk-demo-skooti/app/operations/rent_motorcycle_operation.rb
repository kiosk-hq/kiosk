# frozen_string_literal: true

# Activates a paid reservation of a licence-required motorcycle, for a rider
# attested `age_over_18` and `licence_a`.
class RentMotorcycleOperation
  def self.call(reservation_id:)
    Kiosk::Server::Kyc.require!
    reservation = Rental.own_reservation!(reservation_id)
    reservation.validate!(:rent_motorcycle)
    Rental.require_paid!(reservation)
    Rental.activate!(reservation)
  end
end
