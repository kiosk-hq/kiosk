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
#   RegisterWithoutPoP — register with no proof-of-possession JWS → not 201
#   MissingAuth       — a request with no Authorization → 401
#   GarbageToken      — an unparseable bearer token → 401
#   UnknownQuery      — an unregistered query name → 404
#   UnknownAction     — an unregistered action name → 404
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3002 KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby redteam_suite.rb
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
TOMORROW   = (Date.today + 1).iso8601

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

# Find an open slot time for a 2-top tomorrow, excluding `exclude`.
def open_time(exclude = [])
  rc, avail = post_json("/kiosk/query",
                        { name: "availability", date: TOMORROW, party_size: 2 },
                        bearer(TOKEN_A))
  abort "availability failed (#{rc}): #{JSON.generate(avail)} — run rake demo:setup" unless rc == 200
  rows = (avail["rows"] || []).reject { |r| exclude.include?(r["slot_time"]) }
  slot = rows.first
  abort "no open slot for a 2-top tomorrow (excluding #{exclude.inspect})" unless slot
  slot.fetch("slot_time")
end

# ── Fixture: Alice books a table (target for cross-owner probes) ──────────────
time_a = open_time
rc, alice_book = post_json("/kiosk/run",
                           { name: "book_table", date: TOMORROW, time: time_a, party_size: 2 },
                           bearer(TOKEN_A))
abort "A book_table failed (#{rc}): #{JSON.generate(alice_book)} — run rake demo:setup" unless rc == 200
alice_booking_id = alice_book.dig("value", "booking_id")
abort "no booking_id from A's booking: #{JSON.generate(alice_book)}" unless alice_booking_id

# ── CrossTenantRead — Bob must not see Alice's booking in my_bookings ─────────
rc, b_mine = post_json("/kiosk/query", { name: "my_bookings" }, bearer(TOKEN_B))
b_ids = (b_mine["rows"] || []).map { |r| r["id"] }
record(results, "CrossTenantRead",
       rc == 200 && !b_ids.include?(alice_booking_id),
       "Bob's my_bookings #{b_ids.inspect} excludes Alice's #{alice_booking_id}")

# ── ForgedUserId — Bob books with a forged user_id (Alice's); must be ignored ─
time_b = open_time([time_a])
rc, forged = post_json("/kiosk/run",
                       { name: "book_table", date: TOMORROW, time: time_b, party_size: 2,
                         user_id: ALICE_UUID },
                       bearer(TOKEN_B))
forged_id = forged.dig("value", "booking_id")
# The forged booking must NOT surface in Alice's my_bookings (it belongs to Bob).
rc_a, a_mine = post_json("/kiosk/query", { name: "my_bookings" }, bearer(TOKEN_A))
a_ids = (a_mine["rows"] || []).map { |r| r["id"] }
record(results, "ForgedUserId",
       rc == 200 && rc_a == 200 && !a_ids.include?(forged_id),
       "Alice's bookings #{a_ids.inspect} exclude Bob's forged #{forged_id.inspect}")

# ── CrossOwnerCancel — Bob cancels Alice's booking → 403 ─────────────────────
rc, _ = post_json("/kiosk/run",
                  { name: "cancel_booking", booking_id: alice_booking_id },
                  bearer(TOKEN_B))
record(results, "CrossOwnerCancel", rc == 403, "Bob cancel Alice's booking → #{rc} (want 403)")

# ── RegisterWithoutPoP — register with no proof-of-possession → not 201 ──────
require "openssl"
throwaway_pem = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
rc, _ = post_json("/kiosk/auth/register", { public_key: throwaway_pem })
record(results, "RegisterWithoutPoP", rc != 201, "register with no signed PoP → #{rc} (want != 201)")

# ── MissingAuth — no Authorization header → 401 ──────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "availability", date: TOMORROW, party_size: 2 })
record(results, "MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

# ── GarbageToken — unparseable bearer → 401 ──────────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "availability", date: TOMORROW, party_size: 2 },
                  bearer("not-a-real-token"))
record(results, "GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# ── UnknownQuery — unregistered query name → 404 ─────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "frobnicate" }, bearer(TOKEN_A))
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = post_json("/kiosk/run", { name: "nope" }, bearer(TOKEN_A))
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

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
