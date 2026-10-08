# frozen_string_literal: true

# What both rental verbs share: the principal's own reservation, its payment,
# and the activation that signs the rental token the lock verifies offline.
module Rental
  module_function

  def own_reservation!(reservation_id)
    Reservation.own.reserved.find_by(id: reservation_id) or refuse "reservation not found or not yours"
  end

  def require_paid!(reservation)
    return if reservation.paid?

    if reservation.paying?
      refuse "a payment for this reservation is in progress and its outcome is not yet known — " \
             "re-read my_reservations and start the rental once its payment_state is `paid`; do " \
             "NOT sign a fresh mandate chain while it reads `pending`"
    end
    refuse "this reservation is not paid — pay for it first: POST <endpoint>/pay with the cart " \
           "mandate reserve's pay_hint describes, then call this verb again"
  end

  def activate!(reservation)
    scooter = reservation.scooter
    now     = Time.now.to_i
    token   = RentalTokenIssuer.issue(scooter_code: scooter.code, reservation_id: reservation.id, now: now)
    reservation.active!

    { scooter_code: scooter.code,
      rental_token: token,
      unlock_url:   UnlockLink.url(origin: Kiosk.current_issuer, scooter_code: scooter.code, rental_token: token),
      exp:          RentalTokenIssuer.verify(token: token, now: now).fetch(:exp) }
  end

  def refuse(message)
    raise Kiosk::Server::Errors::Forbidden, message
  end
end
