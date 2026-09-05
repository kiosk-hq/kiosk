# frozen_string_literal: true

# Seed the skooti fleet for the demo, plus the two human rider accounts.
#
# Agents still self-register via /kiosk/auth/register (proof-of-possession
# handshake) and get their OWN credential-less account row. The two humans here
# are the other principal: they sign in at /users/sign_in with a real Devise
# session, which is the channel the account-binding surfaces (device verify
# page, link mint, unlink) authenticate — there is no stub user-IdP, so without
# a seeded human those routed surfaces are unreachable.
#
# A coined Amsterdam micromobility fleet, priced in EUR cents per minute, with
# named vehicles at named pickup docks — so a plain prompt like "rent an
# electric scooter near the Jordaan" or "rent the Amstel Cruiser motorcycle"
# resolves to a concrete row.
#
# Two vehicle kinds:
#   SK-00x — licence-free electric scooters (renting needs NO KYC), €0.15/min,
#            docked at "Jordaan Dock" (3) and "Prinsengracht Pier" (2). SK-001 is
#            seeded FIRST so it keeps the lowest id — the rideflow/redteam
#            drivers browse scooters_available (ORDER BY id) and rent the first
#            row via the licence-free start_rental path.
#   MC-001 — the "Amstel Cruiser", a COMBUSTION-ENGINE motorcycle: renting
#            it is KYC-gated on age_over_18 AND licence_a (category-A driving
#            licence), €0.40/min, docked at "Amstel Garage".

# ── Human rider accounts (Devise credentials) ───────────────────────────────
# Demo-only credentials (development database, reset by every demo:setup).
# STABLE UUIDs so a driver can name a rider without a lookup. Ada is the rider
# who approves an assistant on the verify page; Ben is the SEPARATE account on
# the far side of the isolation boundary.
ADA_ID = "00000000-0000-0000-0000-000000000001"
BEN_ID = "00000000-0000-0000-0000-000000000002"
DEMO_PASSWORD = "skooti-demo-password"

User.find_or_create_by!(id: ADA_ID) do |u|
  u.email    = "ada@example.com"
  u.password = DEMO_PASSWORD
end
User.find_or_create_by!(id: BEN_ID) do |u|
  u.email    = "ben@example.com"
  u.password = DEMO_PASSWORD
end

# Licence-free electric scooters — €0.15/min. Jordaan Dock (3) + Prinsengracht Pier (2).
# SK-001 first so it holds the lowest id (the first-row rental drivers depend on it).
ELECTRIC_SCOOTERS = [
  { code: "SK-001", name: "Jordaan Jet",     dock: "Jordaan Dock",        lat: 52.3739, lng: 4.8809 },
  { code: "SK-002", name: "Canal Cruiser",   dock: "Jordaan Dock",        lat: 52.3741, lng: 4.8811 },
  { code: "SK-003", name: "Vondel Vespa",    dock: "Jordaan Dock",        lat: 52.3743, lng: 4.8813 },
  { code: "SK-004", name: "Amstel Arrow",    dock: "Prinsengracht Pier",  lat: 52.3667, lng: 4.8836 },
  { code: "SK-005", name: "Prinsen Pixie",   dock: "Prinsengracht Pier",  lat: 52.3669, lng: 4.8838 },
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

# The KYC-gated combustion motorcycle — "Amstel Cruiser", €0.40/min.
mc001 = Scooter.find_or_create_by!(code: "MC-001") do |s|
  s.name                = "Amstel Cruiser"
  s.dock                = "Amstel Garage"
  s.status              = "available"
  s.kind                = "motorcycle"
  s.needs_licence       = true
  s.lat                 = 52.3600
  s.lng                 = 4.9020
  s.price_per_min_cents = 40
end

# Human-facing summary: prices shown in EUR (€0.15/min), never raw cents — the
# per-minute rate stays canonical integer cents on the wire.
eur_per_min = ->(cents) { format("€%.2f", cents.to_i / 100.0) }

puts "Seeded: #{User.where.not(email: nil).count} human rider accounts, " \
     "#{seeded_scooters.size} electric scooters (#{eur_per_min.call(seeded_scooters.first.price_per_min_cents)}/min, licence-free) " \
     "at Jordaan Dock + Prinsengracht Pier, and the #{mc001.name} motorcycle #{mc001.code} " \
     "(#{eur_per_min.call(mc001.price_per_min_cents)}/min, KYC-gated: age_over_18 + licence_a) at #{mc001.dock}"
