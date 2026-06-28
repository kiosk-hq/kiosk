# frozen_string_literal: true

# Seed hotel properties and room types for the hoteling demo.
# No human users needed — agents self-register via /kiosk/agents/register.

gran_hotel = Property.find_or_create_by!(name: "Gran Hotel Istanbul") { |p| p.city = "Istanbul" }
RoomType.find_or_create_by!(property: gran_hotel, name: "Standard") { |rt| rt.nightly_price_cents = 8000 }
RoomType.find_or_create_by!(property: gran_hotel, name: "Deluxe")   { |rt| rt.nightly_price_cents = 12000 }
RoomType.find_or_create_by!(property: gran_hotel, name: "Suite")    { |rt| rt.nightly_price_cents = 20000 }

park_ankara = Property.find_or_create_by!(name: "Park Ankara") { |p| p.city = "Ankara" }
RoomType.find_or_create_by!(property: park_ankara, name: "Standard") { |rt| rt.nightly_price_cents = 6000 }
RoomType.find_or_create_by!(property: park_ankara, name: "Deluxe")   { |rt| rt.nightly_price_cents = 9000 }

riviera_izmir = Property.find_or_create_by!(name: "Riviera Izmir") { |p| p.city = "Izmir" }
RoomType.find_or_create_by!(property: riviera_izmir, name: "Standard") { |rt| rt.nightly_price_cents = 7000 }
RoomType.find_or_create_by!(property: riviera_izmir, name: "Sea View")  { |rt| rt.nightly_price_cents = 11000 }
RoomType.find_or_create_by!(property: riviera_izmir, name: "Suite")     { |rt| rt.nightly_price_cents = 18000 }

bosphorus_palace = Property.find_or_create_by!(name: "Bosphorus Palace") { |p| p.city = "Istanbul" }
RoomType.find_or_create_by!(property: bosphorus_palace, name: "Classic")    { |rt| rt.nightly_price_cents = 15000 }
RoomType.find_or_create_by!(property: bosphorus_palace, name: "Bosphorus")  { |rt| rt.nightly_price_cents = 25000 }

cappadocia_cave = Property.find_or_create_by!(name: "Cappadocia Cave Hotel") { |p| p.city = "Nevsehir" }
RoomType.find_or_create_by!(property: cappadocia_cave, name: "Cave Standard") { |rt| rt.nightly_price_cents = 10000 }
RoomType.find_or_create_by!(property: cappadocia_cave, name: "Cave Suite")    { |rt| rt.nightly_price_cents = 16000 }

puts "Seeded: #{Property.count} properties, #{RoomType.count} room types"
