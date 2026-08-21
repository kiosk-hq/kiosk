# frozen_string_literal: true

# atablefor — a restaurant AGGREGATOR across a few Lisbon neighbourhoods, taking
# table reservations over the Kiosk wire. All names are COINED — no real brand.
#
# The roster is STATIC (restaurants + their named physical tables never go
# stale). What rolls is the SEATING (date + time): availability computes the
# upcoming evening seatings relative to NOW in Europe/Lisbon (see
# app/models/seatings.rb), so it is never stale, yet the tables are FINITE and CAN sell
# out for a given seating.
#
# NO AGENT IS SEEDED, and since T-104 none can be. An assistant EARNS its
# principal over the wire at /kiosk/auth/register (the proof-of-possession
# handshake, Equihash-tolled), which mints its agent row plus a fresh headless
# users row of its own — that is what satisfies `Booking belongs_to :user`
# (load_defaults 8.1 requires the association) for script/book_flow.rb,
# script/isolation_flow.rb and the bin/demo walkthrough alike. There is no
# self-asserted `agent:u-…:a-…:r-…` bearer left for a driver to write down, and
# therefore no stub principal to seed a users row for.
#
# What IS seeded is the HUMAN half: real Devise account holders. A diner signs
# in at /users/sign_in, mints a link code, and an assistant redeems it — from
# then on that assistant acts for the diner's ACCOUNT and its bookings tie to
# it (demo:binding), surfacing on the PUBLIC reservations board under the
# diner's display name.
#
# TWO diners, not one, because the adversarial drivers need two DISTINCT
# account holders on either side of the isolation boundary:
# script/redteam_suite.rb binds an assistant to each (script/bound_assistant.rb)
# and asserts that neither can read or cancel the other's booking. Their UUIDs
# are stable so a driver — or a psql ground-truth check — can name an account
# without a lookup.
# Demo-only credentials (development database, reset by every demo:setup).

DINER_A_ID = "00000000-0000-0000-0000-000000000001"
DINER_B_ID = "00000000-0000-0000-0000-000000000002"
DEMO_PASSWORD = "atablefor-demo-password"

# Diego — the headline diner, the one demo:binding walks and the one whose
# reservation the board shows by name.
DINER_EMAIL = "diego@example.com"
DINER_NAME  = "Diego Marlowe"
User.find_or_create_by!(id: DINER_A_ID) do |u|
  u.email        = DINER_EMAIL
  u.password     = DEMO_PASSWORD
  u.display_name = DINER_NAME
end

# Bea — the SEPARATE account on the far side of the isolation boundary. She has
# the same shape as Diego on purpose: the redteam battery's cross-owner probes
# only mean something if the account it attacks from is as real as the one it
# attacks.
SECOND_DINER_EMAIL = "bea@example.com"
SECOND_DINER_NAME  = "Bea Ferreira"
User.find_or_create_by!(id: DINER_B_ID) do |u|
  u.email        = SECOND_DINER_EMAIL
  u.password     = DEMO_PASSWORD
  u.display_name = SECOND_DINER_NAME
end

# The public /reservations board is deliberately EMPTY at rest: it mirrors ONLY
# real bookings made over the Kiosk wire, so a viewer sees a genuine reservation
# land under its diner's name rather than a pre-seeded scene. No synthetic board
# reservations are seeded here.

# ── The restaurant roster — ~5 Lisbon spots, coined names, varied tables ─────
# Each restaurant offers its named tables for EVERY upcoming seating (19/20/21).
# deposit_eur is a DISPLAY-ONLY no-show hold on prime tables (terrace/window),
# shown in EUR and settled at the restaurant — atablefor advertises NO `pay`
# verb, so no money ever crosses the wire.
ROSTER = [
  { name: "Tasca do Tejo",     neighborhood: "Alfama",     cuisine: "Portuguese tavern",
    tables: [
      ["Window 6",  2, 10], ["Bar 1", 2, 0], ["Terrace 2", 4, 10], ["Garden 4", 6, 0],
    ] },
  { name: "Adega da Graça",    neighborhood: "Graça",      cuisine: "Grilled fish",
    tables: [
      ["Miradouro 1", 2, 12], ["Nook 3", 2, 0], ["Hall 5", 4, 0], ["Long 8", 8, 15],
    ] },
  { name: "Cantinho do Bairro", neighborhood: "Bairro Alto", cuisine: "Petiscos & wine",
    tables: [
      ["Counter 2", 2, 0], ["Corner 4", 4, 8], ["Snug 6", 6, 0],
    ] },
  { name: "Marisqueira Belém", neighborhood: "Belém",      cuisine: "Seafood",
    tables: [
      ["Riverside 3", 2, 15], ["Riverside 4", 2, 15], ["Family 6", 6, 0], ["Banquet 10", 10, 20],
    ] },
  { name: "Forno do Príncipe", neighborhood: "Príncipe Real", cuisine: "Wood-fired",
    tables: [
      ["Booth 1", 2, 0], ["Booth 2", 2, 0], ["Terrace 5", 5, 12], ["Chef 4", 4, 10],
    ] },
].freeze

ROSTER.each do |r|
  restaurant = Restaurant.find_or_create_by!(name: r[:name]) do |rec|
    rec.neighborhood = r[:neighborhood]
    rec.cuisine      = r[:cuisine]
  end
  # Idempotent backfill if a row predates the neighborhood/cuisine columns.
  restaurant.update!(neighborhood: r[:neighborhood]) if restaurant.neighborhood.blank?
  restaurant.update!(cuisine:      r[:cuisine])      if restaurant.cuisine.blank?

  r[:tables].each do |label, capacity, deposit|
    RestaurantTable.find_or_create_by!(restaurant: restaurant, label: label) do |t|
      t.capacity    = capacity
      t.deposit_eur = deposit
    end
  end
end

puts "Seeded: diners #{DINER_EMAIL} + #{SECOND_DINER_EMAIL} (sign-in password #{DEMO_PASSWORD}), " \
     "#{Restaurant.count} restaurants across Lisbon, " \
     "#{RestaurantTable.count} physical tables, " \
     "#{Booking.where(status: 'confirmed').count} reservations on the board (empty at rest). " \
     "Upcoming seatings (Lisbon): #{Seatings.upcoming.map { |d, t| "#{d} #{t}" }.join(', ')}"
