# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver (table-booking domain).
#
# Proves app-layer predicates enforce cross-tenant denial for bookings:
#
#   HEADLINE (owner-scoped cancel) — B cannot cancel A's booking:
#     Principal A books table oA. Principal B calls run cancel_booking with
#     booking_id = oA → MUST be 403. cancel_booking gates on ownership
#     (booking.user_id == current_user), so a cross-principal cancel is rejected
#     and A's booking stays confirmed.
#
#   Assertion 1 — exclusion:
#     Principal A books oA. Principal B calls query my_bookings
#     → B's rows must NOT contain oA.
#
#   Assertion 2 — forged owner_id ignored:
#     Principal B calls run book_table with a forged user_id arg (A's user_id).
#     → The created booking belongs to B (kiosk.current_user_id()), not A.
#       B's my_bookings contains oB; A's my_bookings does NOT contain oB; and
#       the DB bookings.user_id for oB is B's, not A's.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3002 \
#   KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "date"
require "jwt"
require "json"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, headers = {})
  uri = URI(url)
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

require_relative "lib/equihash_register"

# Register a fresh agent, solving the register PoW transparently when the
# provider gates registration (KIOSK_POW_REGISTER_DEMO=1).
def register(server, issuer)
  _key, reg = equihash_register(
    server: server, issuer: issuer,
    get_json: method(:get_json), post_json: method(:post_json),
  )
  { agent_id: reg.fetch("agent_id"), user_id: reg.fetch("user_id"), token: reg.fetch("access_token") }
end

# Find an open (restaurant, table, seating) row for a party across the
# aggregator, excluding any
# already-claimed (restaurant_table_id, seating_at) pairs. Returns the full row.
def find_open_slot(server, token, party, exclude: [])
  rc, avail = post_json(
    "#{server}/kiosk/query",
    { name: "availability", party_size: party },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "availability failed (#{rc}): #{JSON.generate(avail)}" unless rc == 200
  rows = avail.fetch("rows", [])
  rows = rows.reject { |r| exclude.include?([r["restaurant_table_id"], r["seating_at"]]) }
  slot = rows.first
  abort "no open table for party #{party}: #{JSON.generate(avail)}" unless slot
  slot
end

# Book the given availability row as `token`, optionally injecting extra args.
def book_slot(server, token, slot, party, extra = {})
  post_json(
    "#{server}/kiosk/run",
    { name: "book_table", restaurant_id: slot.fetch("restaurant_id"),
      restaurant_table_id: slot.fetch("restaurant_table_id"),
      date: slot.fetch("seating_date"), time: slot.fetch("seating_time"),
      party_size: party }.merge(extra),
    { "Authorization" => "Bearer #{token}" },
  )
end

# ── Step 1: Register Principal A and Principal B ─────────────────────────────
a = register(SERVER, ISSUER)
b = register(SERVER, ISSUER)

# ── Step 2: A books table oA (a 2-top) ───────────────────────────────────────
slot_a = find_open_slot(SERVER, a[:token], 2)
rc, book_a = book_slot(SERVER, a[:token], slot_a, 2)
abort "A book_table failed (#{rc}): #{JSON.generate(book_a)}" unless rc == 200
booking_id_a = book_a.dig("value", "booking_id")
abort "A's booking_id missing: #{JSON.generate(book_a)}" unless booking_id_a

# ── Step 3: B tries cancel_booking on A's booking (HEADLINE — MUST be 403) ────
b_cancel_on_a_status, _b_cancel_on_a = post_json(
  "#{SERVER}/kiosk/run",
  { name: "cancel_booking", booking_id: booking_id_a },
  { "Authorization" => "Bearer #{b[:token]}" },
)

# ── Step 4: B queries my_bookings BEFORE booking (Assertion 1 data) ──────────
rc, b_before_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_bookings" },
  { "Authorization" => "Bearer #{b[:token]}" },
)
abort "B my_bookings (before) failed (#{rc}): #{JSON.generate(b_before_resp)}" unless rc == 200
b_booking_ids_before = (b_before_resp["rows"] || []).map { |r| r["booking_id"] }

# ── Step 5: B books with a FORGED user_id arg (Assertion 2) ──────────────────
# B picks a different open (table, seating) than A's, and injects A's user_id —
# the server must ignore the forged arg and attribute the booking to B.
slot_b = find_open_slot(SERVER, b[:token], 2,
                        exclude: [[slot_a["restaurant_table_id"], slot_a["seating_at"]]])
rc, forged_resp = book_slot(SERVER, b[:token], slot_b, 2,
                            user_id: a[:user_id])  # adversarial: B supplies A's user_id
abort "B forged book_table failed (#{rc}): #{JSON.generate(forged_resp)}" unless rc == 200
booking_id_b = forged_resp.dig("value", "booking_id")
abort "B's forged booking_id missing: #{JSON.generate(forged_resp)}" unless booking_id_b

# ── Step 6: B queries my_bookings AFTER booking (must include oB, not oA) ─────
rc, b_after_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_bookings" },
  { "Authorization" => "Bearer #{b[:token]}" },
)
abort "B my_bookings (after) failed (#{rc}): #{JSON.generate(b_after_resp)}" unless rc == 200
b_booking_ids_after = (b_after_resp["rows"] || []).map { |r| r["booking_id"] }

# ── Step 7: A queries my_bookings AFTER B's forged booking (must NOT include oB) ─
rc, a_after_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_bookings" },
  { "Authorization" => "Bearer #{a[:token]}" },
)
abort "A my_bookings (after) failed (#{rc}): #{JSON.generate(a_after_resp)}" unless rc == 200
a_booking_ids_after = (a_after_resp["rows"] || []).map { |r| r["booking_id"] }

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:               a[:user_id],
  user_id_b:               b[:user_id],
  agent_id_a:              a[:agent_id],
  agent_id_b:              b[:agent_id],
  booking_id_a:            booking_id_a,
  booking_id_b:            booking_id_b,
  b_cancel_on_a_status:    b_cancel_on_a_status,
  b_booking_ids_before:    b_booking_ids_before,
  b_booking_ids_after:     b_booking_ids_after,
  a_booking_ids_after:     a_booking_ids_after,
)
