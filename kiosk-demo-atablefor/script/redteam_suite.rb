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
#   ForgedUserId      — a forged user_id on book_table is REFUSED (400
#                       bad_request naming it), and Bob's legitimate booking
#                       never surfaces under Alice
#   CrossOwnerCancel  — Bob cancel_booking on Alice's booking → 403
#   MalformedUuidArg  — a junk booking_id on cancel_booking is a typed 400
#                       with no SQL internals on the wire — never a 500
#   RegisterWithoutPoP — register with no proof-of-possession JWS → not 201
#   MissingAuth       — a request with no Authorization → 401
#   GarbageToken      — an unparseable bearer token → 401
#   UnknownQuery      — an unregistered query name → 404
#   UnknownAction     — an unregistered action name → 404
#   RetiredWire       — the deleted 0.3 `POST /kiosk/{query,run}` answer an
#                       ordinary 404: no privileged endpoint left to attack
#   MethodMismatch    — a GET at an action's path is 405 + `Allow: POST`, never
#                       a silent 404
#   InvalidFilterIsNotAnEmptyList — an availability filter naming a seating
#     time, a date or a NEIGHBOURHOOD that does not exist is a typed 400
#     NAMING the valid values, never a 200 with an empty rows array and never
#     a 500 (K-717 and T-090, and K-691 before them)
#
# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` carrying its arguments
# in the query string; an action is `POST <endpoint>/<action-name>` carrying
# them as the JSON body. A success body IS the result; an error is an RFC 9457
# problem document whose branch point is the TOP-LEVEL `code`.
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

def get_json(path, params = {}, headers = {})
  uri = URI("#{SERVER}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  req = Net::HTTP::Get.new(uri, headers)
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
  rc, avail = get_json("/kiosk/availability", { party_size: 2 }, bearer(TOKEN_A))
  abort "availability failed (#{rc}): #{JSON.generate(avail)} — run rake demo:setup" unless rc == 200
  rows = Array(avail).reject { |r| exclude.include?([r["restaurant_table_id"], r["seating_at"]]) }
  slot = rows.first
  abort "no open table for a 2-top (excluding #{exclude.inspect})" unless slot
  slot
end

# Book an availability row as `token`, optionally injecting extra args.
def book_slot(token, slot, extra = {})
  post_json("/kiosk/book_table",
            { restaurant_id: slot.fetch("restaurant_id"),
              restaurant_table_id: slot.fetch("restaurant_table_id"),
              date: slot.fetch("seating_date"), time: slot.fetch("seating_time"),
              party_size: 2 }.merge(extra),
            bearer(token))
end

# ── Fixture: Alice books a table (target for cross-owner probes) ──────────────
slot_a = open_slot
rc, alice_book = book_slot(TOKEN_A, slot_a)
abort "A book_table failed (#{rc}): #{JSON.generate(alice_book)} — run rake demo:setup" unless rc == 200
alice_booking_id = alice_book["booking_id"]
abort "no booking_id from A's booking: #{JSON.generate(alice_book)}" unless alice_booking_id

# ── CrossTenantRead — Bob must not see Alice's booking in my_bookings ─────────
rc, b_mine = get_json("/kiosk/my_bookings", {}, bearer(TOKEN_B))
b_ids = Array(b_mine).map { |r| r["booking_id"] }
record(results, "CrossTenantRead",
       rc == 200 && !b_ids.include?(alice_booking_id),
       "Bob's my_bookings #{b_ids.inspect} excludes Alice's #{alice_booking_id}")

# ── ForgedUserId — Bob books with a forged user_id (Alice's) ─────────────────
#
# THIS BEAT CHANGED SHAPE AT 0.4 AND GOT STRONGER, so it is worth saying what it
# now proves. Through 0.3 the forged argument was ACCEPTED by the wire and
# IGNORED by the handler, and the proof was indirect: the created booking did
# not surface in Alice's my_bookings. On the 0.4 wire `input_schema` is
# validated on every call and `book_table` declares
# `additionalProperties: false` — the principal is not one of its inputs — so
# the forgery is REFUSED before the handler runs, with a typed 400 naming the
# offending parameter. Both halves are asserted: the wire refuses it, AND
# nothing belonging to Bob appears under Alice. The refusal writes nothing, so
# the seating it named is still free for the legitimate booking below.
slot_b = open_slot([[slot_a["restaurant_table_id"], slot_a["seating_at"]]])
rc, forged = book_slot(TOKEN_B, slot_b, user_id: ALICE_UUID)
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("user_id")

# And the principal really does come from the token, not from anything the
# caller sent: Bob's LEGITIMATE booking lands under Bob and never under Alice.
rc_b, bobs = book_slot(TOKEN_B, slot_b)
bob_booking_id = bobs["booking_id"]
rc_a, a_mine = get_json("/kiosk/my_bookings", {}, bearer(TOKEN_A))
a_ids = Array(a_mine).map { |r| r["booking_id"] }
record(results, "ForgedUserId",
       refused && rc_b == 200 && rc_a == 200 && !a_ids.include?(bob_booking_id),
       "forged user_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming user_id); " \
       "Alice's bookings #{a_ids.inspect} exclude Bob's #{bob_booking_id.inspect}")

# ── CrossOwnerCancel — Bob cancels Alice's booking → 403 ─────────────────────
rc, _ = post_json("/kiosk/cancel_booking",
                  { booking_id: alice_booking_id },
                  bearer(TOKEN_B))
record(results, "CrossOwnerCancel", rc == 403, "Bob cancel Alice's booking → #{rc} (want 403)")

# ── MalformedUuidArg — a junk booking_id must be a typed 400, never a 500 ────
# K-581/K-582: cancel_booking casts its booking_id `::uuid`. Before the
# UuidCheck guard, a malformed value made Postgres raise
# InvalidTextRepresentation, which is not a Kiosk error and escaped as a raw 500
# carrying the PG message. Three properties are asserted, not one: the status is
# 400 (a client mistake reported as such), the problem document's TOP-LEVEL
# `code` is the typed `bad_request` an assistant can branch on, and NO SQL
# internals reach the wire.
#
# Since 0.4 the refusal usually comes one layer EARLIER than it used to:
# `cancel_booking` declares `booking_id` as `{type: "string", format: "uuid"}`
# and `input_schema` is validated on every call, so the schema layer answers
# most of these before {WireArguments.booking_id} runs. The three properties
# asserted are unchanged — that is the point of asserting properties rather
# than a sentence — and the handler guard remains as defence in depth.
MALFORMED_IDS = ["not-a-uuid", "1; DROP TABLE bookings", "", "  "].freeze
SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

def uuid_guard_verdict(path, body_for)
  MALFORMED_IDS.map do |junk|
    rc, body = post_json(path, body_for.call(junk), bearer(TOKEN_A))
    raw = JSON.generate(body)
    leak = SQL_INTERNALS.find { |needle| raw.include?(needle) }
    ok = rc == 400 && body["code"] == "bad_request" && leak.nil?
    [ok, "#{junk.inspect}→#{rc}/#{body['code'].inspect}#{leak ? " LEAK #{leak}" : ''}"]
  end
end

cancel_probes = uuid_guard_verdict("/kiosk/cancel_booking", ->(junk) { { booking_id: junk } })
record(results, "MalformedUuidArg", cancel_probes.all? { |ok, _| ok },
       "cancel_booking with a malformed booking_id → #{cancel_probes.map(&:last).join(', ')} " \
       "(want 400/\"bad_request\" and no SQL internals)")

# ── RegisterWithoutPoP — register with no proof-of-possession → not 201 ──────
require "openssl"
throwaway_pem = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
rc, _ = post_json("/kiosk/auth/register", { public_key: throwaway_pem })
record(results, "RegisterWithoutPoP", rc != 201, "register with no signed PoP → #{rc} (want != 201)")

# ── MissingAuth — no Authorization header → 401 ──────────────────────────────
rc, _ = get_json("/kiosk/availability", { party_size: 2 })
record(results, "MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

# ── GarbageToken — unparseable bearer → 401 ──────────────────────────────────
rc, _ = get_json("/kiosk/availability", { party_size: 2 }, bearer("not-a-real-token"))
record(results, "GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# ── UnknownQuery — unregistered query name → 404 ─────────────────────────────
rc, _ = get_json("/kiosk/frobnicate", {}, bearer(TOKEN_A))
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = post_json("/kiosk/nope", {}, bearer(TOKEN_A))
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── RetiredWire — the deleted 0.3 endpoints are GONE, not tombstoned ─────────
# T-074 = A was a hard cut. `POST /kiosk/query` now reaches the per-verb
# controller as a verb literally named "query", which nobody registered, so it
# answers the ordinary 404 — no privileged endpoint, no compatibility payload,
# no second conformance surface to attack.
retired = %w[query run].map do |name|
  rc, body = post_json("/kiosk/#{name}", { name: "availability", party_size: 2 }, bearer(TOKEN_A))
  [rc == 404 && body["code"] == "not_found", "#{name}→#{rc}/#{body['code'].inspect}"]
end
record(results, "RetiredWire", retired.all? { |ok, _| ok },
       "0.3 endpoints #{retired.map(&:last).join(', ')} (want 404/\"not_found\")")

# ── MethodMismatch — a GET at an action's path is 405, never a silent 404 ────
# The resource EXISTS; answering 404 would be a lie about it, and a caller that
# read 404 as "this operator cannot do that" would give up on a verb it could
# have called correctly.
uri405 = URI("#{SERVER}/kiosk/book_table")
res405 = Net::HTTP.new(uri405.host, uri405.port)
              .request(Net::HTTP::Get.new(uri405, bearer(TOKEN_A)))
body405 = (JSON.parse(res405.body) rescue {})
record(results, "MethodMismatch",
       res405.code.to_i == 405 && body405["code"] == "method_not_allowed" &&
         res405["allow"].to_s.upcase.include?("POST"),
       "GET an action → #{res405.code}/#{body405['code'].inspect} Allow=#{res405['allow'].inspect} " \
       "(want 405/\"method_not_allowed\"/POST)")

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
# WHICH LAYER ANSWERS EACH ONE MOVED AT 0.4, AND THE ASSERTION DELIBERATELY
# DOES NOT CARE. `input_schema` is validated on every per-verb call now, so
# `time=18:00` is refused by the DECLARED `enum` before the handler runs —
# ``value at `/time` is not one of: ["19:00", "20:00", "21:00"]`` — where 0.3
# reached {WireArguments.seating_time}'s prose. The out-of-horizon `date` still
# reaches the handler guard, because no `enum` written at declaration time can
# name a horizon that rolls forward daily. Both are checked for the same thing:
# a TYPED 400 whose detail NAMES the valid values, which is what an assistant
# actually recovers from — not a sentence a particular layer happened to
# phrase.
#
# The assertion is a TYPED 400 that NAMES the valid values — not merely
# "not 200". An unnamed 400 would refuse correctly and still leave the
# assistant fetching the schema to find out what it should have sent, and the
# K-691 property this beat was born for (the empty path is not a crash) is
# still covered: a 500 fails this just as it failed the old one. The
# non-empty positive control stays, and it is what keeps the beat from passing
# against a handler that refuses everything.
#
# THE THIRD FILTER JOINED THE BEAT UNDER T-090. `neighborhood` was the last of
# `availability`'s three arguments still answering `200 []` to a value the
# aggregator does not serve, which is the same indistinguishable-from-sold-out
# answer the other two stopped giving under K-717. Its served set is
# DB-DERIVED, so it can never be an `enum` — the refusal comes from
# {WireArguments.neighborhood} and names the neighbourhoods that exist, exactly
# as the `date` guard names the horizon.
FAR_FUTURE = (Date.today + 3650).iso8601
invalid_filter_probes = [
  ["time=18:00 (valid pattern, not a seating)",
   { party_size: 2, time: "18:00" }, %w[19:00 20:00 21:00]],
  ["date=#{FAR_FUTURE} (valid date, past the horizon)",
   { party_size: 2, date: FAR_FUTURE }, ["upcoming seatings"]],
  ["neighborhood=Atlantis (well-formed, unserved — T-090)",
   { party_size: 2, neighborhood: "Atlantis" }, ["Alfama"]],
  ["both filters, no overlap",
   { party_size: 2, time: "18:00", date: FAR_FUTURE }, %w[19:00 20:00 21:00]],
].map do |label, args, named|
  rc, resp = get_json("/kiosk/availability", args, bearer(TOKEN_A))
  code   = resp.is_a?(Hash) ? resp["code"] : nil
  detail = resp.is_a?(Hash) ? resp["detail"].to_s : ""
  names  = named.all? { |value| detail.include?(value) }
  ok = rc == 400 && code == "bad_request" && names
  [ok, "#{label} → #{rc}/#{code.inspect}#{ok ? " naming #{named.join(", ")}" : "/#{JSON.generate(resp)[0, 160]}"}"]
end
rc_ctl, ctl = get_json("/kiosk/availability", { party_size: 2 }, bearer(TOKEN_A))
control_ok = rc_ctl == 200 && Array(ctl).any?
record(results, "InvalidFilterIsNotAnEmptyList",
       invalid_filter_probes.all? { |ok, _| ok } && control_ok,
       "#{invalid_filter_probes.map(&:last).join(', ')}; CONTROL unfiltered → " \
       "#{rc_ctl}/#{(rc_ctl == 200 ? Array(ctl).size : 0)} rows " \
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
