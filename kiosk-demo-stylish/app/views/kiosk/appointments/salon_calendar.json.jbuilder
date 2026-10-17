# frozen_string_literal: true

json.array! @appointments do |appointment|
  json.extract! appointment, :id, :salon_id
  json.partial! 'clock', appointment: appointment
  json.service_id appointment.service_id
  json.service appointment.service&.name
  json.price_cents appointment.price_cents
  json.kind 'booking'
  json.currency 'EUR'
  json.price_eur Service.format_eur(appointment.price_cents)
end
if @owner
  forecast_cents = @appointments.sum { it.price_cents.to_i }
  json.child! do
    json.summary 'forecast'
    json.bookings @appointments.size
    json.currency 'EUR'
    json.forecast_cents forecast_cents
    json.forecast_eur Service.format_eur(forecast_cents)
  end
end
