json.array! @search.room_types.order(:nightly_price_cents) do |room_type|
  json.room_type_id room_type.id
  json.extract! room_type, :name, :nightly_price_cents
  json.currency 'eur'
end
