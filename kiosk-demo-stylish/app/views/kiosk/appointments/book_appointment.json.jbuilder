json.appointment_id @appointment.id
json.salon_id @appointment.salon_id
json.partial! 'clock', appointment: @appointment
if (service = @appointment.service)
  json.service service.name
  json.currency 'EUR'
  json.extract! service, :price_cents, :price_eur
end
