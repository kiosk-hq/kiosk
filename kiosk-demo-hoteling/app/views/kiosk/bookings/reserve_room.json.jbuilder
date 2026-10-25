# frozen_string_literal: true

room_type = @booking.room_type
json.booking_id @booking.id
json.total_cents @booking.total_cents
json.currency 'eur'
json.nights @booking.nights
json.nightly_price_cents room_type.nightly_price_cents
json.checkout_jwt @booking.checkout([{ room_type: room_type.name, qty: @booking.nights,
                                       price_cents: room_type.nightly_price_cents }])
