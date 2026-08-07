# frozen_string_literal: true

# Synthetic principals + evergreen availability for the stylish demo.
#
# CUSTOMERS (visitors) — Alice and Bob, with stable UUIDs the assistant scripts
# use in `Authorization: Bearer agent:u-<uuid>:a-<agent>:r-<role>` headers. Both
# get Devise credentials so the account-binding walkthrough can sign in through
# the real /users/sign_in form (Alice approves the assistant link there).
#
# STAFF — Combette on Park's own people (roles-from-IdP): one OWNER and SEVEN
# STYLISTS, each with a `staff_role`. Their assistant, when linked (W5,
# role-carrying StubUserIdp session), inherits that role so `salon_calendar`
# gates on it: an owner-linked assistant sees the whole book (all seven chairs +
# any bookings) plus the FORECASTED € revenue total, a stylist only their own
# chair + own bookings.
#
# AVAILABILITY (K-446) — the salon's STRUCTURE is SEVEN stylists, each offering
# ONE open bookable slot (a service + a EUR price). This is EVERGREEN: the seven
# open slots are always bookable — there are NO synthetic dated appointments and
# NO reseed cron, so the demo never goes empty as the calendar day rolls over.
# The salon starts with ZERO bookings; real bookings (public.appointments)
# accumulate as visitors book during the demo. The staff forecast is projected
# from the seven slot prices (what the day earns if the open slots fill) and
# reflects actual bookings as they happen — computed from real rows, never a
# fixed number.

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

# ── SEVEN stylists, each with ONE open bookable slot (evergreen availability). ─
# Bea (…b1) and Cleo (…b2) keep the stable UUIDs the roles/redteam drivers
# drive; the other five are salon staff too. Each stylist offers one service at
# its menu price, captured onto the slot so the forecast is a real € figure.
#
# Forecast the OWNER sees = sum of the seven open-slot prices (what the day
# earns if every open slot fills):
#   Bea   Colour        €90
#   Cleo  Cut & Colour  €120
#   Dana  Cut & Blow-dry €50
#   Esme  Cut           €35
#   Faye  Beard trim    €20
#   Gwen  Cut & Blow-dry €50
#   Hana  Cut           €35
#   ── forecast ─────────  €400
STYLISTS = [
  { id: "00000000-0000-0000-0000-0000000000b1", name: "Bea",  email: "bea@combette.example",  service: :colour },
  { id: "00000000-0000-0000-0000-0000000000b2", name: "Cleo", email: "cleo@combette.example", service: :cut_colour },
  { id: "00000000-0000-0000-0000-0000000000b3", name: "Dana", email: "dana@combette.example", service: :cut_blowdry },
  { id: "00000000-0000-0000-0000-0000000000b4", name: "Esme", email: "esme@combette.example", service: :cut },
  { id: "00000000-0000-0000-0000-0000000000b5", name: "Faye", email: "faye@combette.example", service: :beard_trim },
  { id: "00000000-0000-0000-0000-0000000000b6", name: "Gwen", email: "gwen@combette.example", service: :cut_blowdry },
  { id: "00000000-0000-0000-0000-0000000000b7", name: "Hana", email: "hana@combette.example", service: :cut },
].freeze

STYLISTS.each do |st|
  stylist = User.find_or_create_by!(id: st[:id]) do |u|
    u.email      = st[:email]
    u.password   = DEMO_PASSWORD
    u.staff_role = "stylist"
  end
  svc = services.fetch(st[:service])
  # Idempotent: one open slot per stylist. Re-seeding does not multiply rows.
  StylistSlot.find_or_create_by!(stylist_id: stylist.id, salon: salon) do |slot|
    slot.service_id  = svc.id
    slot.price_cents = svc.price_cents
    slot.label       = "Next available with #{st[:name]}"
  end
end

forecast_cents = StylistSlot.sum(:price_cents)

puts "Seeded: 2 customers/visitors (#{ALICE_ID}, #{BOB_ID}; sign-in alice@example.com / #{DEMO_PASSWORD})"
puts "        #{STYLISTS.size + 1} staff — owner #{OWNER_ID}, #{STYLISTS.size} stylists"
puts "        1 salon (#{salon.name}); #{services.size}-service EUR menu"
puts "        #{StylistSlot.count} OPEN slots (evergreen availability; 0 bookings — visitors book during the demo)"
puts "        forecasted revenue if the open slots fill: €#{forecast_cents / 100}"
