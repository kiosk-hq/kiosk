# frozen_string_literal: true
json.array! @reservations do |reservation|
  json.reservation_id reservation.id
  json.scooter_code reservation.scooter.code
  json.extract! reservation, :status, :payment_state
end
