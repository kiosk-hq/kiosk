# frozen_string_literal: true

# The price this operator quoted for the reservation a checkout pays for: the
# scooter's per-minute price, the one minute the pay step settles upfront — what
# `c.checkout_price_checker` answers. Kiosk::Server::PaymentClaim checks the rest.
# A hold that has lapsed is refused before any money moves.
module PriceChecker
  def self.call(reservation_id, _lines)
    price, held_until = Reservation.joins(:scooter).where(id: reservation_id)
                                   .pick(Scooter.arel_table[:price_per_min_cents], :held_until)
    return "this reservation's hold lapsed — reserve a vehicle again, then pay for the new one" unless held_until&.future?

    price
  end
end
