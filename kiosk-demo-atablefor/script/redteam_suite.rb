# frozen_string_literal: true

# Adversarial regression battery for atablefor (restaurant table-booking).
#
# Runs a set of attacks against the live surface (availability / my_bookings
# queries; book_table / cancel_booking actions) and asserts each is BLOCKED.
# atablefor has no payment or KYC surface, so the battery covers the attacks
# that actually apply — cross-tenant reads, forged principal args, cross-owner
# cancels, and the auth/dispatch boundary.
#
# Scenarios (each must be BLOCKED):
#   CrossTenantRead   — Bob's my_bookings must NOT contain Alice's booking
#   ForgedUserId      — forged user_id on book_table ignored (booking belongs to Bob)
#   CrossOwnerCancel  — Bob cancel_booking on Alice's booking → 403
#   MalformedUuidArg  — a junk booking_id on cancel_booking is a typed 400
#                       with no SQL internals on the wire — never a 500
#   RegisterWithoutPoP — register with no proof-of-possession JWS → not 201
#   MissingAuth       — a request with no Authorization → 401
#   GarbageToken      — an unparseable bearer token → 401
#   UnknownQuery      — an unregistered query name → 404
#   UnknownAction     — an unregistered action name → 404
#   InvalidFilterIsNotAnEmptyList — an availability filter naming a seating
#     that does not exist is a typed 400 NAMING the valid values, never a
#     200 with an empty rows array and never a 500 (K-717, and K-691 before it)
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3002 KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby script/redteam_suite.rb
#
# Exits 0 when every scenario is BLOCKED (0 BREACH); exits 1 on any BREACH.
# A BREACH = a real hole in atablefor — fix the app, not the scenario.

require "date"
require "json"
require "net/http"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

ALICE_UUID = "00000000-0000-0000-0000-000000000001"
BOB_UUID   = "00000000-0000-0000-0000-000000000002"
TOKEN_A    = "agent:u-#{ALICE_UUID}:a-alice-redteam:r-customer"
TOKEN_B    = "agent:u-#{BOB_UUID}:a-bob-redteam:r-customer"

def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def bearer(token) = { "Authorization" => "Bearer #{token}" }

results = []
def record(results, name, blocked, detail)
  results << { name: name, blocked: blocked, detail: detail }
  tag = blocked ? "BLOCKED" : "BREACH "
  puts "  #{tag}  #{name} — #{detail}"
end

# Find an open (restaurant, table, seating) row for a 2-top across the
# aggregator, excluding any [restaurant_table_id, seating_at] pairs.
def open_slot(exclude = [])
  rc, avail = post_json("/kiosk/query",
                        { name: "availability", party_size: 2 },
                        bearer(TOKEN_A))
  abort "availability failed (#{rc}): #{JSON.generate(avail)} — run rake demo:setup" unless rc == 200
  rows = (avail["rows"] || []).reject { |r| exclude.include?([r["restaurant_table_id"], r["seating_at"]]) }
  slot = rows.first
  abort "no open table for a 2-top (excluding #{exclude.inspect})" unless slot
  slot
end

# Book an availability row as `token`, optionally injecting extra args.
def book_slot(token, slot, extra = {})
  post_json("/kiosk/run",
            { name: "book_table", restaurant_id: slot.fetch("restaurant_id"),
              restaurant_table_id: slot.fetch("restaurant_table_id"),
              date: slot.fetch("seating_date"), time: slot.fetch("seating_time"),
              party_size: 2 }.merge(extra),
            bearer(token))
end

# ── Fixture: Alice books a table (target for cross-owner probes) ──────────────
slot_a = open_slot
rc, alice_book = book_slot(TOKEN_A, slot_a)
abort "A book_table failed (#{rc}): #{JSON.generate(alice_book)} — run rake demo:setup" unless rc == 200
alice_booking_id = alice_book.dig("value", "booking_id")
abort "no booking_id from A's booking: #{JSON.generate(alice_book)}" unless alice_booking_id

# ── CrossTenantRead — Bob must not see Alice's booking in my_bookings ─────────
rc, b_mine = post_json("/kiosk/query", { name: "my_bookings" }, bearer(TOKEN_B))
b_ids = (b_mine["rows"] || []).map { |r| r["booking_id"] }
record(results, "CrossTenantRead",
       rc == 200 && !b_ids.include?(alice_booking_id),
       "Bob's my_bookings #{b_ids.inspect} excludes Alice's #{alice_booking_id}")

# ── ForgedUserId — Bob books with a forged user_id (Alice's); must be ignored ─
slot_b = open_slot([[slot_a["restaurant_table_id"], slot_a["seating_at"]]])
rc, forged = book_slot(TOKEN_B, slot_b, user_id: ALICE_UUID)
forged_id = forged.dig("value", "booking_id")
# The forged booking must NOT surface in Alice's my_bookings (it belongs to Bob).
rc_a, a_mine = post_json("/kiosk/query", { name: "my_bookings" }, bearer(TOKEN_A))
a_ids = (a_mine["rows"] || []).map { |r| r["booking_id"] }
record(results, "ForgedUserId",
       rc == 200 && rc_a == 200 && !a_ids.include?(forged_id),
       "Alice's bookings #{a_ids.inspect} exclude Bob's forged #{forged_id.inspect}")

# ── CrossOwnerCancel — Bob cancels Alice's booking → 403 ─────────────────────
rc, _ = post_json("/kiosk/run",
                  { name: "cancel_booking", booking_id: alice_booking_id },
                  bearer(TOKEN_B))
record(results, "CrossOwnerCancel", rc == 403, "Bob cancel Alice's booking → #{rc} (want 403)")

# ── MalformedUuidArg — a junk booking_id must be a typed 400, never a 500 ────
# K-581/K-582: cancel_booking casts its booking_id `::uuid`. Before the
# UuidCheck guard, a malformed value made Postgres raise
# InvalidTextRepresentation, which is not a Kiosk error and escaped as a raw 500
# carrying the PG message. Three properties are asserted, not one: the status is
# 400 (a client mistake reported as such), the envelope code is the typed
# `bad_request` an assistant can branch on, and NO SQL internals reach the wire.
MALFORMED_IDS = ["not-a-uuid", "1; DROP TABLE bookings", "", "  "].freeze
SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

def uuid_guard_verdict(path, body_for)
  MALFORMED_IDS.map do |junk|
    rc, body = post_json(path, body_for.call(junk), bearer(TOKEN_A))
    raw = JSON.generate(body)
    leak = SQL_INTERNALS.find { |needle| raw.include?(needle) }
    ok = rc == 400 && body.dig("error", "code") == "bad_request" && leak.nil?
    [ok, "#{junk.inspect}→#{rc}/#{body.dig('error', 'code').inspect}#{leak ? " LEAK #{leak}" : ''}"]
  end
end

cancel_probes = uuid_guard_verdict("/kiosk/run", ->(junk) { { name: "cancel_booking", booking_id: junk } })
record(results, "MalformedUuidArg", cancel_probes.all? { |ok, _| ok },
       "cancel_booking with a malformed booking_id → #{cancel_probes.map(&:last).join(', ')} " \
       "(want 400/\"bad_request\" and no SQL internals)")

# ── RegisterWithoutPoP — register with no proof-of-possession → not 201 ──────
require "openssl"
throwaway_pem = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
rc, _ = post_json("/kiosk/auth/register", { public_key: throwaway_pem })
record(results, "RegisterWithoutPoP", rc != 201, "register with no signed PoP → #{rc} (want != 201)")

# ── MissingAuth — no Authorization header → 401 ──────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "availability", party_size: 2 })
record(results, "MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

# ── GarbageToken — unparseable bearer → 401 ──────────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "availability", party_size: 2 },
                  bearer("not-a-real-token"))
record(results, "GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# ── UnknownQuery — unregistered query name → 404 ─────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "frobnicate" }, bearer(TOKEN_A))
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = post_json("/kiosk/run", { name: "nope" }, bearer(TOKEN_A))
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── InvalidFilterIsNotAnEmptyList (K-717, was EmptyAvailabilityIsNotACrash) ──
# THE BEAT FLIPPED, AND THE FLIP IS THE POINT. These three probes used to
# assert HTTP 200 with an empty rows array. Phil's K-717 decision (2026-08-19)
# makes that the wrong answer: «если передан неверный входной параметр, ответ
# должен быть http 400 bad request, не пустой список, и должна быть ошибка с
# описанием». From the assistant's side `200 []` for a mistyped filter is
# indistinguishable from a sold-out night, so a typo and a full house read the
# same — which is exactly what philslist's `post_listing` refuses to do, and
# that is now the house position fleet-wide.
#
# What each probe sends is unchanged, and both are still values the OLD
# descriptor accepted: `time: "18:00"` matched the retired
# "^[0-2][0-9]:[0-5][0-9]$" pattern without being a seating, and any date past
# the rolling horizon is a valid `format: "date"`. `time` is now an `enum` on
# the descriptor and `date` keeps an explicit handler guard, because a horizon
# that rolls forward daily cannot be named in a schema written at declaration
# time.
#
# The assertion is a TYPED 400 that NAMES the valid values — not merely
# "not 200". An unnamed 400 would refuse correctly and still leave the
# assistant fetching the schema to find out what it should have sent, and the
# K-691 property this beat was born for (the empty path is not a crash) is
# still covered: a 500 fails this just as it failed the old one. The
# non-empty positive control stays, and it is what keeps the beat from passing
# against a handler that refuses everything.
FAR_FUTURE = (Date.today + 3650).iso8601
invalid_filter_probes = [
  ["time=18:00 (valid pattern, not a seating)",
   { name: "availability", party_size: 2, time: "18:00" }, %w[19:00 20:00 21:00]],
  ["date=#{FAR_FUTURE} (valid date, past the horizon)",
   { name: "availability", party_size: 2, date: FAR_FUTURE }, ["upcoming seatings"]],
  ["both filters, no overlap",
   { name: "availability", party_size: 2, time: "18:00", date: FAR_FUTURE }, %w[19:00 20:00 21:00]],
].map do |label, body, named|
  rc, resp = post_json("/kiosk/query", body, bearer(TOKEN_A))
  code    = resp.is_a?(Hash) ? resp.dig("error", "code") : nil
  message = resp.is_a?(Hash) ? resp.dig("error", "message").to_s : ""
  names   = named.all? { |value| message.include?(value) }
  ok = rc == 400 && code == "bad_request" && names
  [ok, "#{label} → #{rc}/#{code.inspect}#{ok ? " naming #{named.join(", ")}" : "/#{JSON.generate(resp)[0, 160]}"}"]
end
rc_ctl, ctl = post_json("/kiosk/query", { name: "availability", party_size: 2 }, bearer(TOKEN_A))
control_ok = rc_ctl == 200 && (ctl["rows"] || []).any?
record(results, "InvalidFilterIsNotAnEmptyList",
       invalid_filter_probes.all? { |ok, _| ok } && control_ok,
       "#{invalid_filter_probes.map(&:last).join(', ')}; CONTROL unfiltered → " \
       "#{rc_ctl}/#{(ctl["rows"] || []).size} rows " \
       "(want 400 bad_request naming the valid values for each filter, and a non-empty control)")

# ── Verdict ──────────────────────────────────────────────────────────────────
breaches = results.reject { |r| r[:blocked] }
puts JSON.generate(scenarios: results.size, blocked: results.count { |r| r[:blocked] }, breaches: breaches.map { |r| r[:name] })

if breaches.empty?
  puts "\n  redteam: all #{results.size} scenarios BLOCKED."
  exit 0
else
  puts "\n  redteam: #{breaches.size} BREACH(es): #{breaches.map { |r| r[:name] }.join(', ')}"
  exit 1
end
