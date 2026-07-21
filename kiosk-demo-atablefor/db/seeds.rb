# frozen_string_literal: true

# Synthetic restaurant "Mamma Pizza" taking table reservations, with a set of
# bookable tables offered across a few evenings.
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
# account (demo:binding). Given Devise credentials on the walkthrough stub UUID
# so the seeded principal doubles as the human account holder.
# Demo-only credentials (development database, reset by every demo:setup).
DINER_EMAIL    = "diego@example.com"
DINER_PASSWORD = "atablefor-demo-password"
User.find_or_create_by!(id: WALKTHROUGH_STUB_USER_ID) do |u|
  u.email    = DINER_EMAIL
  u.password = DINER_PASSWORD
end
User.find_or_create_by!(id: REDTEAM_STUB_USER_ID)

pizza = Restaurant.find_or_create_by!(name: "Mamma Pizza")

# Bookable tables across the next few evenings. "tomorrow" carries the
# headline slot (a 2-top at 20:00 — "book a table for two tomorrow at 8").
# availability(date, party_size) returns the open slots that seat the party.
today = Date.today

slots = [
  # date offset (days from today), table label, capacity, time
  [1, "T1",       2, "20:00"],  # the headline: 2-top, tomorrow, 8pm
  [1, "T2",       2, "18:30"],
  [1, "T3",       4, "20:00"],
  [1, "T4",       4, "21:30"],
  [1, "Window 6", 6, "19:00"],
  [2, "T1",       2, "20:00"],
  [2, "T3",       4, "19:30"],
  [2, "Window 6", 6, "21:00"],
  [3, "T2",       2, "18:00"],
  [3, "T4",       4, "20:30"],
]

slots.each do |offset, label, capacity, time|
  TableSlot.find_or_create_by!(
    restaurant:  pizza,
    table_label: label,
    slot_date:   today + offset,
    slot_time:   time,
  ) do |s|
    s.capacity = capacity
    s.status   = "open"
  end
end

puts "Seeded: 1 human diner (#{WALKTHROUGH_STUB_USER_ID}; sign-in #{DINER_EMAIL} / #{DINER_PASSWORD}), " \
     "1 restaurant (#{pizza.name}), #{TableSlot.count} bookable table slots"
