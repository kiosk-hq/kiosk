# frozen_string_literal: true

# Activates a paid reservation of a vehicle that needs a licence, for a rider
# attested `age_over_18` and the licence attribute of the vehicle's category.
class RentMotorcycleOperation
  def self.call(reservation_id:)
    reservation = Rental.own_reservation!(reservation_id)
    reservation.validate!(:rent_motorcycle)
    require_licence!(reservation.scooter)
    Rental.require_paid!(reservation)
    Rental.activate!(reservation)
  end

  def self.require_licence!(scooter)
    Kiosk::Server::Kyc.require!(
      scooter.kyc_claims,
      detail: "#{scooter.code} needs a licence of category #{scooter.licence_category}: the verified attributes " \
              "#{scooter.kyc_claims.join(' and ')}. If your human's licence does not cover that category, a new " \
              'check gives the same answer; offer a vehicle from scooters_available whose licence_category it covers.'
    )
  end
end
