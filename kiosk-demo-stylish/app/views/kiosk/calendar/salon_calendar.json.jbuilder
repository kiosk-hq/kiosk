# frozen_string_literal: true

json.array! @appointments do |appointment|
  json.extract! appointment, :id, :salon_id
  json.partial! 'kiosk/appointments/clock', appointment: appointment
  json.service_id appointment.service_id
  json.service appointment.service&.name
  json.price_cents appointment.price_cents
  json.currency 'eur'
  json.price_eur Service.format_eur(appointment.price_cents)
end
