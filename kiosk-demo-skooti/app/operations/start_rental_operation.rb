# frozen_string_literal: true

# Activates a paid reservation of a licence-free vehicle. No KYC.
class StartRentalOperation
  def self.call(reservation_id:)
    reservation = Rental.own_reservation!(reservation_id)
    unless reservation.scooter.licence_free?
      raise Kiosk::Server::Errors::BadRequest.new(
        "#{reservation.scooter.code} is a licence-required motorcycle — use rent_motorcycle " \
        "for licence-required vehicles",
        hint: "POST <endpoint>/rent_motorcycle with this reservation_id instead; it requires " \
              "the KYC attributes age_over_18 and licence_a — if you do not have them yet, " \
              "POST <endpoint>/request_kyc first",
      )
    end
    Rental.require_paid!(reservation)
    Rental.activate!(reservation)
  end
end
