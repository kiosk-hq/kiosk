# frozen_string_literal: true

scooter = @reservation.scooter
json.reservation_id @reservation.id
json.price_per_min_cents scooter.price_per_min_cents
json.currency 'eur'
json.checkout_jwt @reservation.checkout([{ scooter_code: scooter.code, qty: 1,
                                           price_cents: scooter.price_per_min_cents }])
