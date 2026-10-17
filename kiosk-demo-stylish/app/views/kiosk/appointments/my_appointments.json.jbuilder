json.array! @appointments do |appointment|
  json.extract! appointment, :id, :salon_id
  json.partial! "clock", appointment: appointment
end
