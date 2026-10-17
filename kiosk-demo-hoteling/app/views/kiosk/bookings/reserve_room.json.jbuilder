# frozen_string_literal: true

nightly_price_cents = @booking.room_type.nightly_price_cents
json.booking_id @booking.id
json.total_cents @booking.total_cents
json.currency 'eur'
json.nights @booking.nights
json.nightly_price_cents nightly_price_cents
json.pay_hint "sign a cart mandate in EUR with total_amount_cents #{@booking.total_cents} and " \
              "one line item {\"qty\": #{@booking.nights}, \"price_cents\": #{nightly_price_cents}, " \
              "\"booking_id\": \"#{@booking.id}\"}, then call pay within #{Booking::PAY_WINDOW.inspect}"
