# frozen_string_literal: true

# Synthetic principals + an evergreen SERVICE MENU for the stylish demo.
#
# CUSTOMERS (visitors) — Alice and Bob, with stable UUIDs and real Devise
# credentials. The credentials are the load-bearing part: since T-104 no driver
# can hand itself a principal, so every one of them signs its human in through
# the real /users/sign_in form and binds an assistant through the shipped
# ceremony (register → link → claim, lib/bound_assistant.rb). The UUIDs stay
# stable because the claim REBINDS the assistant onto the human's account,
# which is what makes "Alice's rows" mean these ids.
#
# STAFF — Combette on Park's OWNER (roles-from-IdP): one owner with a
# `staff_role`. Their assistant, when linked over the owner's own Devise
# session, inherits that role so `salon_calendar` gates on it: an owner-linked
# assistant sees the whole book (every booking made) plus the FORECAST € total;
# a customer sees only their own bookings and no forecast.
#
# THE MENU (K-446) — the salon's structure is a small SERVICE MENU (a handful of
# services, each a EUR price). This is EVERGREEN and INFINITE-CAPACITY: every
# service is ALWAYS bookable, OVERBOOKING is allowed (a visitor can book any
# service any number of times), so the salon can always take you and the demo
# never goes empty or stale. There are NO dated appointments and NO reseed cron.
# The salon starts with ZERO bookings; real bookings (public.appointments)
# accumulate as visitors book. The staff forecast is summed from the ACTUAL
# bookings' captured prices — it starts at €0 and grows as visitors book,
# computed from real rows, never a fixed number.

ALICE_ID = "00000000-0000-0000-0000-000000000001"
BOB_ID   = "00000000-0000-0000-0000-000000000002"

# Salon owner — stable UUID the roles demo drives.
OWNER_ID = "00000000-0000-0000-0000-0000000000a0"

# Demo-only credentials (development database, reset by every demo:setup).
DEMO_PASSWORD = "combette-demo-password"

User.find_or_create_by!(id: ALICE_ID) do |u|
  u.email    = "alice@example.com"
  u.password = DEMO_PASSWORD
end
User.find_or_create_by!(id: BOB_ID) do |u|
  u.email    = "bob@example.com"
  u.password = DEMO_PASSWORD
end

# Owner carries a staff_role + Devise credentials (they sign in to the salon to
# link their assistant, the same real session the binding surfaces use).
owner = User.find_or_create_by!(id: OWNER_ID) do |u|
  u.email      = "owner@combette.example"
  u.password   = DEMO_PASSWORD
  u.staff_role = "owner"
end

salon = Salon.find_or_create_by!(name: "Combette on Park")

# ── Service menu (EUR) — coined/generic names, prices in euro cents. ──────────
# This IS the bookable structure: every service is always open (evergreen,
# infinite capacity — overbooking allowed). Static; not dated appointments.
MENU = {
  cut:          { name: "Cut",            price_cents: 3500 },  # €35
  cut_blowdry:  { name: "Cut & Blow-dry", price_cents: 5000 },  # €50
  colour:       { name: "Colour",         price_cents: 9000 },  # €90
  cut_colour:   { name: "Cut & Colour",   price_cents: 12000 }, # €120
  beard_trim:   { name: "Beard trim",     price_cents: 2000 },  # €20
}.freeze

services = MENU.transform_values do |m|
  Service.find_or_create_by!(name: m[:name]) { |s| s.price_cents = m[:price_cents] }
end

puts "Seeded: 2 customers/visitors (#{ALICE_ID}, #{BOB_ID}; sign-in alice@example.com / #{DEMO_PASSWORD})"
puts "        1 staff — owner #{OWNER_ID} (owner@combette.example)"
puts "        1 salon (#{salon.name}); #{services.size}-service EUR menu (always bookable — overbooking OK)"
puts "        0 bookings — visitors book during the demo; the owner's forecast grows from €0"
