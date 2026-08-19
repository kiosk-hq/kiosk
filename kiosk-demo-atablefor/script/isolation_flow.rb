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
#   Assertion 2 — the principal is not an input:
#     Principal B calls POST /kiosk/book_table with a forged user_id arg (A's
#     user_id) → 400 bad_request naming user_id: `book_table` publishes
#     `additionalProperties: false` and does not declare `user_id`, so the
#     declared input contract refuses the forgery BEFORE the handler runs.
#     → And, on a LEGITIMATE call, the booking B does make belongs to B: B's
#       my_bookings contains oB, A's my_bookings does NOT, and the DB
#       bookings.user_id for oB is B's — ownership comes from the token.
#
# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the query string; an action is `POST <endpoint>/<action-name>` with them as
# the JSON body. There is no `name` field and no /query or /run endpoint. A
# success body IS the result — a bare array from a non-paginating query, the
# action's own object from an action — and an error is an RFC 9457 problem
# document whose branch point is the TOP-LEVEL `code`.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3002 \
#   KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby script/isolation_flow.rb
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

def get_json(url, params = {}, headers = {})
  uri = URI(url)
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

require_relative "../lib/equihash_register"

# Register a fresh agent, solving the register PoW transparently.
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
  rc, avail = get_json(
    "#{server}/kiosk/availability",
    { party_size: party },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "availability failed (#{rc}): #{JSON.generate(avail)}" unless rc == 200
  rows = Array(avail)
  rows = rows.reject { |r| exclude.include?([r["restaurant_table_id"], r["seating_at"]]) }
  slot = rows.first
  abort "no open table for party #{party}: #{JSON.generate(avail)}" unless slot
  slot
end

# Book the given availability row as `token`, optionally injecting extra args.
def book_slot(server, token, slot, party, extra = {})
  post_json(
    "#{server}/kiosk/book_table",
    { restaurant_id: slot.fetch("restaurant_id"),
      restaurant_table_id: slot.fetch("restaurant_table_id"),
      date: slot.fetch("seating_date"), time: slot.fetch("seating_time"),
      party_size: party }.merge(extra),
    { "Authorization" => "Bearer #{token}" },
  )
end

# A my_bookings read as `token` — a query, so a GET, and the answer is the bare
# array of rows.
def my_booking_ids(server, token, label)
  rc, resp = get_json("#{server}/kiosk/my_bookings", {}, { "Authorization" => "Bearer #{token}" })
  abort "#{label} my_bookings failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  Array(resp).map { |r| r["booking_id"] }
end

# ── Step 1: Register Principal A and Principal B ─────────────────────────────
a = register(SERVER, ISSUER)
b = register(SERVER, ISSUER)

# ── Step 2: A books table oA (a 2-top) ───────────────────────────────────────
slot_a = find_open_slot(SERVER, a[:token], 2)
rc, book_a = book_slot(SERVER, a[:token], slot_a, 2)
abort "A book_table failed (#{rc}): #{JSON.generate(book_a)}" unless rc == 200
booking_id_a = book_a["booking_id"]
abort "A's booking_id missing: #{JSON.generate(book_a)}" unless booking_id_a

# ── Step 3: B tries cancel_booking on A's booking (HEADLINE — MUST be 403) ────
b_cancel_on_a_status, _b_cancel_on_a = post_json(
  "#{SERVER}/kiosk/cancel_booking",
  { booking_id: booking_id_a },
  { "Authorization" => "Bearer #{b[:token]}" },
)

# ── Step 4: B queries my_bookings BEFORE booking (Assertion 1 data) ──────────
b_booking_ids_before = my_booking_ids(SERVER, b[:token], "B (before)")

# ── Step 5a: B books with a FORGED user_id arg (Assertion 2a) ────────────────
#
# B's token identifies B; the forged arg supplies A's user_id. On the 0.4 wire
# this is REFUSED before the handler runs: `book_table` publishes
# `additionalProperties: false` and does not declare `user_id` — the principal
# is not one of its inputs — so the declared input contract answers a typed 400
# naming the parameter. (Through 0.3 the argument was accepted and silently
# ignored; refusing it is the stricter answer and the one the published
# contract requires.) The refusal writes nothing, so no seating is consumed and
# the legitimate booking below can take the very slot this attempt named.
slot_b = find_open_slot(SERVER, b[:token], 2,
                        exclude: [[slot_a["restaurant_table_id"], slot_a["seating_at"]]])
forged_rc, forged_resp = book_slot(SERVER, b[:token], slot_b, 2,
                                   user_id: a[:user_id])  # adversarial: B supplies A's user_id
STDERR.puts "  B book_table with a forged user_id → #{forged_rc} #{forged_resp["code"].inspect}"

# ── Step 5b: and the second half, which the refusal does not itself prove ────
# Ownership is taken from the AUTHENTICATED identity. B books LEGITIMATELY; the
# rake task reads the row back and asserts bookings.user_id == B.
rc, book_b = book_slot(SERVER, b[:token], slot_b, 2)
abort "B book_table failed (#{rc}): #{JSON.generate(book_b)}" unless rc == 200
booking_id_b = book_b["booking_id"]
abort "B's booking_id missing: #{JSON.generate(book_b)}" unless booking_id_b

# ── Step 6: B queries my_bookings AFTER booking (must include oB, not oA) ─────
b_booking_ids_after = my_booking_ids(SERVER, b[:token], "B (after)")

# ── Step 7: A queries my_bookings AFTER B's booking (must NOT include oB) ─────
a_booking_ids_after = my_booking_ids(SERVER, a[:token], "A (after)")

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:               a[:user_id],
  user_id_b:               b[:user_id],
  agent_id_a:              a[:agent_id],
  agent_id_b:              b[:agent_id],
  booking_id_a:            booking_id_a,
  booking_id_b:            booking_id_b,
  b_cancel_on_a_status:    b_cancel_on_a_status,
  forged_refusal:          [forged_rc, forged_resp["code"], forged_resp["detail"]],
  b_booking_ids_before:    b_booking_ids_before,
  b_booking_ids_after:     b_booking_ids_after,
  a_booking_ids_after:     a_booking_ids_after,
)
