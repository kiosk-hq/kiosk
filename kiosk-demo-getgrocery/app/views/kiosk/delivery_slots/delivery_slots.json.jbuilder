zone = @search.zone
json.array! DeliverySlots.bookable(@search.day, zone) do |slot_at|
  json.slot_at slot_at.iso8601
  json.label DeliverySlots.label(slot_at, zone)
  json.timezone zone.name
  json.district @search.district
end
