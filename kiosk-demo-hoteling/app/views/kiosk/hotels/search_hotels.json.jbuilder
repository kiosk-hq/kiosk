# frozen_string_literal: true
json.array! @hotels do |hotel|
  json.property_id hotel.id
  json.extract! hotel, :name, :neighbourhood, :stars, :from_price_cents, :room_type_count
  json.currency 'eur'
end
