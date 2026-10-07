# frozen_string_literal: true

# The price this operator quoted for the reservation a cart pays for: the
# scooter's per-minute price, the one minute the pay step settles upfront — what
# `c.cart_price_checker` answers. Kiosk::Server::PaymentClaim checks the rest.
module PriceChecker
  def self.call(reservation_id, _lines)
    Reservation.joins(:scooter).where(id: reservation_id).pick(Scooter.arel_table[:price_per_min_cents])
  end
end
