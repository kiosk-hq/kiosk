# frozen_string_literal: true

json.array! @salons do |salon|
  json.salon_id salon.id
  json.extract! salon, :name, :timezone
  note = salon.timezone_note(Kiosk.reader_zone)
  json.timezone_note note if note
end
