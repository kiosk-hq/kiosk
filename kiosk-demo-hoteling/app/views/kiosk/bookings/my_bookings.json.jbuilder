# frozen_string_literal: true

json.array! @bookings do |booking|
  json.booking_id booking.id
  json.extract! booking, :property_id, :room_type_id
  json.check_in booking.check_in.iso8601
  json.check_out booking.check_out.iso8601
  json.extract! booking, :total_cents
  json.status booking.stay_status
  json.extract! booking, :payment_state, :confirmation_code
end
