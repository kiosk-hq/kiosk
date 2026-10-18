# frozen_string_literal: true

price = @reservation.scooter.price_per_min_cents
json.reservation_id @reservation.id
json.price_per_min_cents price
json.currency 'eur'
json.cart @reservation.cart([{ qty: 1, price_cents: price }])
