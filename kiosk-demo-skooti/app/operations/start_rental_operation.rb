# frozen_string_literal: true

# Activates a paid reservation of a licence-free vehicle. No KYC.
class StartRentalOperation
  def self.call(reservation_id:)
    reservation = Rental.own_reservation!(reservation_id)
    reservation.validate!(:start_rental)
    Rental.require_paid!(reservation)
    Rental.activate!(reservation)
  end
end
