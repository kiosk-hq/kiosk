# frozen_string_literal: true

# Seed hotel properties and room types for the hoteling demo.
# No human users needed — agents self-register via /kiosk/auth/register (proof-of-possession handshake).

gran_hotel = Property.find_or_create_by!(name: "Gran Hotel Istanbul") { |p| p.city = "Istanbul" }
RoomType.find_or_create_by!(property: gran_hotel, name: "Standard") { |rt| rt.nightly_price_cents = 8000 }
RoomType.find_or_create_by!(property: gran_hotel, name: "Deluxe")   { |rt| rt.nightly_price_cents = 12000 }
RoomType.find_or_create_by!(property: gran_hotel, name: "Suite")    { |rt| rt.nightly_price_cents = 20000 }

kadikoy_suites = Property.find_or_create_by!(name: "Kadikoy Suites") { |p| p.city = "Istanbul" }
RoomType.find_or_create_by!(property: kadikoy_suites, name: "Standard") { |rt| rt.nightly_price_cents = 6000 }
RoomType.find_or_create_by!(property: kadikoy_suites, name: "Deluxe")   { |rt| rt.nightly_price_cents = 9000 }

sultanahmet_court = Property.find_or_create_by!(name: "Sultanahmet Court") { |p| p.city = "Istanbul" }
RoomType.find_or_create_by!(property: sultanahmet_court, name: "Standard")    { |rt| rt.nightly_price_cents = 7000 }
RoomType.find_or_create_by!(property: sultanahmet_court, name: "Harbor View") { |rt| rt.nightly_price_cents = 11000 }
RoomType.find_or_create_by!(property: sultanahmet_court, name: "Suite")       { |rt| rt.nightly_price_cents = 18000 }

bosphorus_palace = Property.find_or_create_by!(name: "Bosphorus Palace") { |p| p.city = "Istanbul" }
RoomType.find_or_create_by!(property: bosphorus_palace, name: "Classic")    { |rt| rt.nightly_price_cents = 15000 }
RoomType.find_or_create_by!(property: bosphorus_palace, name: "Bosphorus")  { |rt| rt.nightly_price_cents = 25000 }

galata_house = Property.find_or_create_by!(name: "Galata House") { |p| p.city = "Istanbul" }
RoomType.find_or_create_by!(property: galata_house, name: "Standard") { |rt| rt.nightly_price_cents = 10000 }
RoomType.find_or_create_by!(property: galata_house, name: "Suite")    { |rt| rt.nightly_price_cents = 16000 }

puts "Seeded: #{Property.count} properties, #{RoomType.count} room types"
