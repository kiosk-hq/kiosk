json.array! @scooters do |scooter|
  json.extract! scooter, :code, :name, :dock, :kind, :needs_licence, :lat, :lng, :price_per_min_cents
  json.currency "eur"
end
