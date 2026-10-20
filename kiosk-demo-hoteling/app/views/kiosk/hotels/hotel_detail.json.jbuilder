# frozen_string_literal: true

json.array! [@property] do |property|
  json.property_id property.id
  json.extract! property, :name, :neighbourhood, :stars, :address, :amenities
  json.currency 'eur'
  json.check_in @search.check_in&.iso8601
  json.check_out @search.check_out&.iso8601
  json.timezone property.timezone
  note = property.timezone_note(Kiosk.reader_zone)
  json.timezone_note note if note
  json.room_types @search.room_types.order(:nightly_price_cents) do |room_type|
    json.room_type_id room_type.id
    json.extract! room_type, :name, :nightly_price_cents
  end
end
