# frozen_string_literal: true

# What both rental verbs share: the customer's own reservation, its payment,
# and the activation that signs the rental token the lock verifies offline.
module Rental
  # A started rental: the signed token for the vehicle and the page that hands it to the lock.
  Unlock = Data.define(:scooter_code, :rental_token, :unlock_url, :exp)

  module_function

  def own_reservation!(reservation_id)
    reservation = Reservation.own.reserved.find_by(id: reservation_id) or refuse 'reservation not found or not yours'
    lapsed!(reservation) unless reservation.held_until.future?
    reservation
  end

  def require_paid!(reservation)
    return if reservation.paid?

    if reservation.paying?
      refuse "this reservation's payment is in progress — re-read my_reservations and start the " \
             'rental once it reads `paid`; do not pay again'
    end
    refuse 'this reservation is not paid — pay for it first (call `pay` with the cart ' \
           "reserve's pay_hint describes), then call this again"
  end

  def activate!(reservation)
    scooter = reservation.scooter
    now     = Time.now.to_i
    token   = RentalTokenIssuer.issue(scooter_code: scooter.code, reservation_id: reservation.id, now: now)
    exp     = RentalTokenIssuer.verify(token: token, now: now).fetch(:exp)
    hold_until!(reservation, Time.zone.at(exp))

    Unlock.new(scooter_code: scooter.code,
               rental_token: token,
               unlock_url: UnlockLink.url(origin: Kiosk.current_issuer, scooter_code: scooter.code, rental_token: token),
               exp:)
  end

  # The vehicle stays held while its rental token can open the lock.
  def hold_until!(reservation, held_until)
    reservation.update!(status: :active, held_until:)
  rescue ActiveRecord::ExclusionViolation
    lapsed!(reservation)
  end

  def lapsed!(reservation)
    raise Kiosk::Server::Errors::Conflict,
          "this reservation's hold on #{reservation.scooter.code} lapsed — reserve a vehicle again"
  end

  def refuse(message)
    raise Kiosk::Server::Errors::Forbidden, message
  end
end
