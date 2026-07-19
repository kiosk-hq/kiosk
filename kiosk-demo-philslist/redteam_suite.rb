# frozen_string_literal: true

# Adversarial regression battery for philslist (non-commerce classifieds).
#
# Runs a set of attacks against the live surface (browse_listings / my_listings
# queries; post_listing / edit_listing / close_listing actions) and asserts each
# is BLOCKED. philslist has no payment or KYC surface, so the battery covers the
# attacks that actually apply — cross-owner reads AND WRITES, forged principal
# args, and the auth/dispatch boundary.
#
# Scenarios (each must be BLOCKED):
#   CrossTenantRead  — Bob's my_listings must NOT contain Alice's listing
#   ForgedUserId     — forged owner_id on post_listing ignored (belongs to Bob)
#   CrossOwnerEdit   — Bob edit_listing on Alice's listing → 403
#   CrossOwnerClose  — Bob close_listing on Alice's listing → 403
#   MissingAuth      — a request with no Authorization → 401
#   GarbageToken     — an unparseable bearer token → 401
#   UnknownQuery     — an unregistered query name → 404
#   UnknownAction    — an unregistered action name → 404
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3001 KIOSK_ISSUER=http://127.0.0.1:3001 \
#   bundle exec ruby redteam_suite.rb
#
# Exits 0 when every scenario is BLOCKED (0 BREACH); exits 1 on any BREACH.
# A BREACH = a real hole in philslist — fix the app, not the scenario.

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

# ── Fixture: Alice posts a listing (target for cross-owner probes) ────────────
rc, alice_post = post_json("/kiosk/run",
                           { name: "post_listing", category_slug: "furniture",
                             title: "Redteam target", body: "Alice's listing" },
                           bearer(TOKEN_A))
abort "A post_listing failed (#{rc}): #{JSON.generate(alice_post)} — run rake demo:setup" unless rc == 200
alice_listing_id = alice_post.dig("value", "listing_id")
abort "no listing_id from A's post: #{JSON.generate(alice_post)}" unless alice_listing_id

# ── CrossTenantRead — Bob must not see Alice's listing in my_listings ─────────
rc, b_mine = post_json("/kiosk/query", { name: "my_listings" }, bearer(TOKEN_B))
b_ids = (b_mine["rows"] || []).map { |r| r["id"] }
record(results, "CrossTenantRead",
       rc == 200 && !b_ids.include?(alice_listing_id),
       "Bob's my_listings #{b_ids.inspect} excludes Alice's #{alice_listing_id}")

# ── ForgedUserId — Bob posts with a forged owner_id (Alice's); must be ignored ─
rc, forged = post_json("/kiosk/run",
                       { name: "post_listing", category_slug: "free",
                         title: "Forged", body: "should be Bob's", owner_id: ALICE_UUID },
                       bearer(TOKEN_B))
forged_id = forged.dig("value", "listing_id")
# The forged listing must NOT surface in Alice's my_listings (it belongs to Bob).
rc_a, a_mine = post_json("/kiosk/query", { name: "my_listings" }, bearer(TOKEN_A))
a_ids = (a_mine["rows"] || []).map { |r| r["id"] }
record(results, "ForgedUserId",
       rc == 200 && rc_a == 200 && !a_ids.include?(forged_id),
       "Alice's list #{a_ids.inspect} excludes Bob's forged #{forged_id.inspect}")

# ── CrossOwnerEdit — Bob edits Alice's listing → 403 ─────────────────────────
rc, _ = post_json("/kiosk/run",
                  { name: "edit_listing", listing_id: alice_listing_id, price_text: "1 TL" },
                  bearer(TOKEN_B))
record(results, "CrossOwnerEdit", rc == 403, "Bob edit Alice's listing → #{rc} (want 403)")

# ── CrossOwnerClose — Bob closes Alice's listing → 403 ───────────────────────
rc, _ = post_json("/kiosk/run",
                  { name: "close_listing", listing_id: alice_listing_id },
                  bearer(TOKEN_B))
record(results, "CrossOwnerClose", rc == 403, "Bob close Alice's listing → #{rc} (want 403)")

# ── MissingAuth — no Authorization header → 401 ──────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "browse_listings" })
record(results, "MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

# ── GarbageToken — unparseable bearer → 401 ──────────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "browse_listings" }, bearer("not-a-real-token"))
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
