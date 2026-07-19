# frozen_string_literal: true

# Synthetic principals for the two audiences the stylish demo now serves.
#
# CUSTOMERS — Alice and Bob, with stable UUIDs the assistant scripts use in
# `Authorization: Bearer agent:u-<uuid>:a-<agent>:r-<role>` headers. Both get
# Devise credentials so the account-binding walkthrough can sign in through the
# real /users/sign_in form (Alice approves the assistant link there).
#
# STAFF — Combette on Park's own people (roles-from-IdP / T-014): one OWNER
# and two STYLISTS, each with a `staff_role`. Their assistant, when linked
# (W5, role-carrying StubUserIdp session), inherits that role so the
# `salon_calendar` query gates on it: owner sees the whole book, a stylist
# only their own chairs. Seeded appointments are assigned across the two
# stylists so the scoping is observable.

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

# Book across the two stylists so `salon_calendar` scoping is observable:
# 2 chairs for Bea, 1 for Cleo. Booked BY customers, ASSIGNED to a stylist.
# (idempotent: keyed on the slot so re-seeding does not multiply rows.)
[
  { customer: ALICE_ID, stylist: stylist1, slot: "2026-08-01T10:00:00Z" },
  { customer: BOB_ID,   stylist: stylist1, slot: "2026-08-01T11:00:00Z" },
  { customer: ALICE_ID, stylist: stylist2, slot: "2026-08-02T14:00:00Z" },
].each do |a|
  Appointment.find_or_create_by!(salon: salon, slot: a[:slot]) do |appt|
    appt.user_id    = a[:customer]
    appt.stylist_id = a[:stylist].id
  end
end

puts "Seeded: 2 customers (#{ALICE_ID}, #{BOB_ID}; sign-in alice@example.com / #{DEMO_PASSWORD})"
puts "        3 staff — owner #{OWNER_ID}, stylists #{STYLIST1_ID}/#{STYLIST2_ID}"
puts "        1 salon (#{salon.name}); 3 staff appointments (2 Bea, 1 Cleo)"
