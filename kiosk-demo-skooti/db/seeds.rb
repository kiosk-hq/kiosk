# frozen_string_literal: true

# Seed a single scooter for the skooti demo.
# No human users needed — agents self-register via /kiosk/auth/register (proof-of-possession handshake).

sk001 = Scooter.find_or_create_by!(code: "SK-001") do |s|
  s.status             = "available"
  s.lat                = 41.0082
  s.lng                = 28.9784
  s.price_per_min_cents = 15
end

puts "Seeded: 1 scooter (#{sk001.code}, #{sk001.price_per_min_cents}¢/min)"
