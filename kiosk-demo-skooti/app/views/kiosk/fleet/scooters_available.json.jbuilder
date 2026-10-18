# frozen_string_literal: true

json.array! @scooters do |scooter|
  json.extract! scooter, :code, :name, :dock, :kind, :lat, :lng, :price_per_min_cents
  json.needs_licence scooter.needs_licence?
  json.currency 'eur'
end
