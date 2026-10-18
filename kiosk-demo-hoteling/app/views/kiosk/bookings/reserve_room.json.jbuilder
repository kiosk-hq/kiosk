# frozen_string_literal: true

nightly_price_cents = @booking.room_type.nightly_price_cents
json.booking_id @booking.id
json.total_cents @booking.total_cents
json.currency 'eur'
json.nights @booking.nights
json.nightly_price_cents nightly_price_cents
json.cart @booking.cart([{ qty: @booking.nights, price_cents: nightly_price_cents }])
