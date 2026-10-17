# frozen_string_literal: true

# The price this hotel quoted for the booking a cart pays for, or why it no
# longer sells it — what `c.cart_price_checker` answers. Kiosk::Server::PaymentClaim
# checks the rest.
module PriceChecker
  def self.call(booking_id, _lines)
    booking = Booking.find(booking_id)
    return booking.total_cents unless booking.pay_by.past?

    "booking #{booking_id} was held until #{booking.pay_by.utc.iso8601}; that pay-by time passed and the " \
      'room was released — reserve it again'
  end
end
