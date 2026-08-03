# frozen_string_literal: true

# Synthetic restaurant "Meydan Meze House" (Beyoğlu, Istanbul) taking table
# reservations over the Kiosk wire, with a set of named, bookable tables offered
# across a few evenings. Coined name — no real brand.
#
# The book_flow.rb / demo:book path self-registers agents via
# /kiosk/auth/register (proof-of-possession handshake), which inserts a fresh
# users row — those principals need no seed. The bin/demo walkthrough instead
# books under one STABLE stub principal (StubIdp token, no PoP round-trip so
# the tour stays curl-readable). Because `Booking belongs_to :user`
# (load_defaults 8.1 requires the association), book_table for that stub
# principal needs a matching users row; seed it here with the same UUID
# bin/demo's AGENT_TOKEN carries. (stylish seeds its Alice/Bob stub users for
# the identical reason.)
# Two stable stub principals: one for the walkthrough / schema probe, and a
# second so the redteam battery (redteam_suite.rb) can drive a cross-owner
# probe with two known identities. Both need a users row because
# `Booking belongs_to :user`.
WALKTHROUGH_STUB_USER_ID = "00000000-0000-0000-0000-000000000001"
REDTEAM_STUB_USER_ID     = "00000000-0000-0000-0000-000000000002"

# The human diner "Diego" — a real account holder at the restaurant. He signs
# in through the Devise form (/users/sign_in) and mints a link code so his AI
# assistant can book on his behalf; the assistant's bookings then tie to this
# account (demo:binding), and each surfaces on the PUBLIC reservations board
# under his display name. Given Devise credentials on the walkthrough stub UUID
# so the seeded principal doubles as the human account holder.
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

# Two board-only diners, used ONLY to seed a couple of EXISTING reservations on
# the public board so it is never empty (and reads as a real, busy restaurant).
# No login credentials — plain account rows referenced by the seeded bookings.
# Deliberately NOT the flow principals (0001 Diego / 0002 redteam): the booking
# flows assert their OWN principal's my_bookings, so board seeds must belong to
# other diners or they'd inflate those counts.
GUEST_DINER_1_ID   = "00000000-0000-0000-0000-000000000003"
GUEST_DINER_1_NAME = "Selin Aydın"
GUEST_DINER_2_ID   = "00000000-0000-0000-0000-000000000004"
GUEST_DINER_2_NAME = "Kerem Bulut"
User.find_or_create_by!(id: GUEST_DINER_1_ID) { |u| u.display_name = GUEST_DINER_1_NAME }
User.find_or_create_by!(id: GUEST_DINER_2_ID) { |u| u.display_name = GUEST_DINER_2_NAME }

meydan = Restaurant.find_or_create_by!(name: "Meydan Meze House") do |r|
  r.neighborhood = "Beyoğlu"
end
# Idempotent backfill if the row predates the neighborhood column.
meydan.update!(neighborhood: "Beyoğlu") if meydan.neighborhood.blank?

# Named tables, seated across three seatings (19:00 early · 20:00 main · 21:00
# late). "tomorrow" (offset 1) carries the headline slot — a 2-top at 20:00, so
# "book a table for two at Meydan Meze House tomorrow at 8" lands verbatim.
# deposit_eur is a DISPLAY-ONLY no-show hold on the prime terrace/window tables,
# shown in EUR and settled at the restaurant — atablefor advertises NO `pay`
# verb, so no money ever crosses the wire.
today = Date.today

# Columns: date offset (days from today), table label, capacity, time, deposit €
slots = [
  # ── tomorrow (offset 1) — the demo's headline evening ──
  [1, "Window 6",  2, "20:00", 10],  # the headline: a 2-top at 8, €10 hold
  [1, "Bar 1",     2, "19:00",  0],
  [1, "Terrace 2", 2, "21:00", 10],
  [1, "Garden 4",  4, "20:00",  0],
  [1, "Terrace 2", 4, "19:00", 10],  # a second Terrace 2 seating (early)
  [1, "Garden 4",  6, "21:00",  0],
  # ── the evening after (offset 2) ──
  [2, "Window 6",  2, "21:00", 10],
  [2, "Bar 1",     2, "20:00",  0],
  [2, "Garden 4",  4, "19:00",  0],
  [2, "Terrace 2", 6, "20:00", 10],
  # ── two nights out (offset 3) ──
  [3, "Bar 1",     2, "19:00",  0],
  [3, "Window 6",  4, "21:00", 10],
  [3, "Garden 4",  4, "20:00",  0],
]

slots.each do |offset, label, capacity, time, deposit|
  TableSlot.find_or_create_by!(
    restaurant:  meydan,
    table_label: label,
    slot_date:   today + offset,
    slot_time:   time,
  ) do |s|
    s.capacity    = capacity
    s.status      = "open"
    s.deposit_eur = deposit
  end
end

# ── Two EXISTING reservations so the public board is never empty ─────────────
# Claim two open slots for the two seeded diners (Diego already has a bound
# assistant path; Selin is board-only). These read on /reservations as
# "party · table · time · <diner name>" alongside any freshly-booked one.
def seed_reservation!(restaurant:, diner_id:, table_label:, offset:, time:, party:)
  slot = TableSlot.find_by(
    restaurant:  restaurant,
    table_label: table_label,
    slot_date:   Date.today + offset,
    slot_time:   time,
    status:      "open",
  )
  return unless slot

  slot.update!(status: "booked")
  Booking.find_or_create_by!(
    user_id:       diner_id,
    restaurant:    restaurant,
    table_slot_id: slot.id,
  ) do |b|
    b.party_size = party
    b.status     = "confirmed"
  end
end

seed_reservation!(restaurant: meydan, diner_id: GUEST_DINER_1_ID,
                  table_label: "Terrace 2", offset: 2, time: "20:00", party: 5)
seed_reservation!(restaurant: meydan, diner_id: GUEST_DINER_2_ID,
                  table_label: "Window 6", offset: 3, time: "21:00", party: 3)

puts "Seeded: 2 named diners (sign-in #{DINER_EMAIL} / #{DINER_PASSWORD}), " \
     "1 restaurant (#{meydan.name}, #{meydan.neighborhood}), " \
     "#{TableSlot.where(status: 'open').count} open + #{TableSlot.where(status: 'booked').count} booked table slots, " \
     "#{Booking.where(status: 'confirmed').count} reservations on the board"
