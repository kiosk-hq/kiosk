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
# The script/book_flow.rb / demo:book path self-registers agents via
# /kiosk/auth/register (proof-of-possession handshake), which inserts a fresh
# users row — those principals need no seed. The bin/demo walkthrough instead
# books under one STABLE stub principal (StubIdp token, no PoP round-trip so the
# tour stays curl-readable). Because `Booking belongs_to :user` (load_defaults
# 8.1 requires the association), book_table for that stub principal needs a
# matching users row; seed it here with the same UUID bin/demo's AGENT_TOKEN
# carries. (stylish seeds its stub users for the identical reason.)
#
# Two stable stub principals: one for the walkthrough / schema probe, and a
# second so the redteam battery (script/redteam_suite.rb) can drive a cross-owner probe
# with two known identities. Both need a users row because
# `Booking belongs_to :user`.

WALKTHROUGH_STUB_USER_ID = "00000000-0000-0000-0000-000000000001"
REDTEAM_STUB_USER_ID     = "00000000-0000-0000-0000-000000000002"

# The human diner "Diego" — a real account holder. He signs in through the
# Devise form (/users/sign_in) and mints a link code so his AI assistant can
# book on his behalf; the assistant's bookings then tie to this account
# (demo:binding), and each surfaces on the PUBLIC reservations board under his
# display name. Given Devise credentials on the walkthrough stub UUID so the
# seeded principal doubles as the human account holder.
# Demo-only credentials (development database, reset by every demo:setup).
DINER_EMAIL    = "diego@example.com"
DINER_PASSWORD = "atablefor-demo-password"
DINER_NAME     = "Diego Marlowe"
User.find_or_create_by!(id: WALKTHROUGH_STUB_USER_ID) do |u|
  u.email        = DINER_EMAIL
  u.password     = DINER_PASSWORD
  u.display_name = DINER_NAME
end
User.find_or_create_by!(id: REDTEAM_STUB_USER_ID)

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

puts "Seeded: Diego (sign-in #{DINER_EMAIL} / #{DINER_PASSWORD}) + redteam stub, " \
     "#{Restaurant.count} restaurants across Lisbon, " \
     "#{RestaurantTable.count} physical tables, " \
     "#{Booking.where(status: 'confirmed').count} reservations on the board (empty at rest). " \
     "Upcoming seatings (Lisbon): #{Seatings.upcoming.map { |d, t| "#{d} #{t}" }.join(', ')}"
