# frozen_string_literal: true

# Seed the skooti fleet for the demo.
# No human users needed — agents self-register via /kiosk/auth/register (proof-of-possession handshake).
#
# A coined Istanbul micromobility fleet, priced in EUR cents per minute, with
# named vehicles at named pickup docks — so a plain prompt like "rent an
# electric scooter near Kadıköy" or "rent the Bosphorus Cruiser motorcycle"
# resolves to a concrete row.
#
# Two vehicle kinds:
#   SK-00x — licence-free electric scooters (renting needs NO KYC), €0.15/min,
#            docked at "Kadıköy Dock" (3) and "Beşiktaş Pier" (2). SK-001 is
#            seeded FIRST so it keeps the lowest id — the rideflow/redteam
#            drivers browse scooters_available (ORDER BY id) and rent the first
#            row via the licence-free start_rental path.
#   MC-001 — the "Bosphorus Cruiser", a COMBUSTION-ENGINE motorcycle: renting
#            it is KYC-gated on age_over_18 AND licence_a (category-A driving
#            licence), €0.40/min, docked at "Karaköy Garage".

# Licence-free electric scooters — €0.15/min. Kadıköy Dock (3) + Beşiktaş Pier (2).
# SK-001 first so it holds the lowest id (the first-row rental drivers depend on it).
ELECTRIC_SCOOTERS = [
  { code: "SK-001", name: "Kadıköy Kartal",  dock: "Kadıköy Dock",  lat: 40.9903, lng: 29.0270 },
  { code: "SK-002", name: "Moda Yıldız",     dock: "Kadıköy Dock",  lat: 40.9905, lng: 29.0272 },
  { code: "SK-003", name: "Bahariye Boncuk", dock: "Kadıköy Dock",  lat: 40.9907, lng: 29.0274 },
  { code: "SK-004", name: "Beşiktaş Balık",  dock: "Beşiktaş Pier", lat: 41.0422, lng: 29.0083 },
  { code: "SK-005", name: "Sinanpaşa Sim",   dock: "Beşiktaş Pier", lat: 41.0424, lng: 29.0085 },
].freeze

seeded_scooters = ELECTRIC_SCOOTERS.map do |attrs|
  Scooter.find_or_create_by!(code: attrs[:code]) do |s|
    s.name                = attrs[:name]
    s.dock                = attrs[:dock]
    s.status              = "available"
    s.kind                = "scooter"
    s.needs_licence       = false
    s.lat                 = attrs[:lat]
    s.lng                 = attrs[:lng]
    s.price_per_min_cents = 15
  end
end

# The KYC-gated combustion motorcycle — "Bosphorus Cruiser", €0.40/min.
mc001 = Scooter.find_or_create_by!(code: "MC-001") do |s|
  s.name                = "Bosphorus Cruiser"
  s.dock                = "Karaköy Garage"
  s.status              = "available"
  s.kind                = "motorcycle"
  s.needs_licence       = true
  s.lat                 = 41.0256
  s.lng                 = 28.9744
  s.price_per_min_cents = 40
end

puts "Seeded: #{seeded_scooters.size} electric scooters (#{seeded_scooters.first.price_per_min_cents}¢/min, licence-free) " \
     "at Kadıköy Dock + Beşiktaş Pier, and the #{mc001.name} motorcycle #{mc001.code} " \
     "(#{mc001.price_per_min_cents}¢/min, KYC-gated: age_over_18 + licence_a) at #{mc001.dock}"
