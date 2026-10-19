# frozen_string_literal: true

json.array! @scooters do |scooter|
  json.extract! scooter, :code, :name, :dock, :kind, :licence_category, :lat, :lng, :price_per_min_cents
  json.currency 'eur'
end
