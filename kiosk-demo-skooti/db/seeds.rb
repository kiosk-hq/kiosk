# frozen_string_literal: true

# Seed the skooti fleet for the demo.
# No human users needed — agents self-register via /kiosk/auth/register (proof-of-possession handshake).
#
# Two vehicle kinds:
#   SK-001 — a licence-free electric scooter (renting needs NO KYC).
#   MC-001 — a COMBUSTION-ENGINE motorcycle: renting it is KYC-gated on
#            age_over_18 AND licence_a (category-A driving licence).

sk001 = Scooter.find_or_create_by!(code: "SK-001") do |s|
  s.status              = "available"
  s.kind                = "scooter"
  s.needs_licence       = false
  s.lat                 = 41.0082
  s.lng                 = 28.9784
  s.price_per_min_cents = 15
end

mc001 = Scooter.find_or_create_by!(code: "MC-001") do |s|
  s.status              = "available"
  s.kind                = "motorcycle"
  s.needs_licence       = true
  s.lat                 = 41.0090
  s.lng                 = 28.9790
  s.price_per_min_cents = 40
end

puts "Seeded: scooter #{sk001.code} (#{sk001.price_per_min_cents}¢/min, licence-free), " \
     "motorcycle #{mc001.code} (#{mc001.price_per_min_cents}¢/min, KYC-gated: age_over_18 + licence_a)"
