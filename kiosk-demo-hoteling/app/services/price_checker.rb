# frozen_string_literal: true

# The price this hotel quoted for the booking a cart pays for — what
# `c.cart_price_checker` answers. Kiosk::Server::PaymentClaim checks the rest.
module PriceChecker
  def self.call(booking_id, _lines) = Booking.where(id: booking_id).pick(:total_cents)
end
