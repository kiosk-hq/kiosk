# frozen_string_literal: true

# Synthetic principals for the two audiences the stylish demo serves.
#
# CUSTOMERS — Alice and Bob, with stable UUIDs the assistant scripts use in
# `Authorization: Bearer agent:u-<uuid>:a-<agent>:r-<role>` headers. Both get
# Devise credentials so the account-binding walkthrough can sign in through the
# real /users/sign_in form (Alice approves the assistant link there).
#
# STAFF — Combette on Park's own people (roles-from-IdP): one OWNER
# and two STYLISTS, each with a `staff_role`. Their assistant, when linked
# (W5, role-carrying StubUserIdp session), inherits that role so the
# `salon_calendar` query gates on it: owner sees the whole book + a EUR
# revenue total, a stylist only their own priced chairs.
#
# SERVICES + PRICES — a real EUR service menu, and a full day of appointments
# TODAY across the two stylists (a mix of services) so the owner's book is
# non-trivial and its revenue total is meaningful. This is what makes the role
# reveal land: an owner-linked assistant sees the whole day + revenue; each
# stylist sees only their own chairs.

ALICE_ID = "00000000-0000-0000-0000-000000000001"
BOB_ID   = "00000000-0000-0000-0000-000000000002"

# Salon staff — stable UUIDs the roles demo drives.
OWNER_ID    = "00000000-0000-0000-0000-0000000000a0" # salon owner
STYLIST1_ID = "00000000-0000-0000-0000-0000000000b1" # stylist Bea
STYLIST2_ID = "00000000-0000-0000-0000-0000000000b2" # stylist Cleo

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

# Staff carry a staff_role and Devise credentials (they sign in to the salon
# to link their assistant, the same real session the binding surfaces use).
owner = User.find_or_create_by!(id: OWNER_ID) do |u|
  u.email      = "owner@combette.example"
  u.password   = DEMO_PASSWORD
  u.staff_role = "owner"
end
stylist1 = User.find_or_create_by!(id: STYLIST1_ID) do |u|
  u.email      = "bea@combette.example"
  u.password   = DEMO_PASSWORD
  u.staff_role = "stylist"
end
stylist2 = User.find_or_create_by!(id: STYLIST2_ID) do |u|
  u.email      = "cleo@combette.example"
  u.password   = DEMO_PASSWORD
  u.staff_role = "stylist"
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

# ── A full day of appointments TODAY across Bea and Cleo. ─────────────────────
# Booked BY customers, ASSIGNED to a stylist, each with a service + its EUR
# price captured on the row. Bea works 4 chairs, Cleo works 3 — so the owner's
# whole-book view is a non-trivial 7 appointments with a real revenue total,
# while Bea sees only her 4 and Cleo only her 3.
#
# Revenue the OWNER sees (sum of the seeded day):
#   Bea : Colour €90 + Cut&Blow-dry €50 + Cut €35 + Beard trim €20   = €195
#   Cleo: Cut&Colour €120 + Cut €35 + Beard trim €20                 = €175
#   ── total ────────────────────────────────────────────────────────  €370
today = Date.current
at = ->(h, m) { Time.utc(today.year, today.month, today.day, h, m).iso8601 }

seed_day = [
  # Bea's chairs
  { customer: ALICE_ID, stylist: stylist1, service: :colour,      slot: at.call(9, 0) },
  { customer: BOB_ID,   stylist: stylist1, service: :cut_blowdry, slot: at.call(10, 30) },
  { customer: ALICE_ID, stylist: stylist1, service: :cut,         slot: at.call(13, 0) },
  { customer: BOB_ID,   stylist: stylist1, service: :beard_trim,  slot: at.call(15, 0) },
  # Cleo's chairs
  { customer: BOB_ID,   stylist: stylist2, service: :cut_colour,  slot: at.call(9, 30) },
  { customer: ALICE_ID, stylist: stylist2, service: :cut,         slot: at.call(12, 0) },
  { customer: BOB_ID,   stylist: stylist2, service: :beard_trim,  slot: at.call(16, 30) },
]

# idempotent: keyed on the slot so re-seeding does not multiply rows.
seed_day.each do |a|
  svc = services.fetch(a[:service])
  Appointment.find_or_create_by!(salon: salon, slot: a[:slot]) do |appt|
    appt.user_id     = a[:customer]
    appt.stylist_id  = a[:stylist].id
    appt.service_id  = svc.id
    appt.price_cents = svc.price_cents
  end
end

revenue_cents = seed_day.sum { |a| services.fetch(a[:service]).price_cents }
bea_count     = seed_day.count { |a| a[:stylist] == stylist1 }
cleo_count    = seed_day.count { |a| a[:stylist] == stylist2 }

puts "Seeded: 2 customers (#{ALICE_ID}, #{BOB_ID}; sign-in alice@example.com / #{DEMO_PASSWORD})"
puts "        3 staff — owner #{OWNER_ID}, stylists #{STYLIST1_ID}/#{STYLIST2_ID}"
puts "        1 salon (#{salon.name}); #{services.size}-service EUR menu"
puts "        #{seed_day.size} appointments today (#{bea_count} Bea, #{cleo_count} Cleo); " \
     "owner revenue total €#{revenue_cents / 100}"
