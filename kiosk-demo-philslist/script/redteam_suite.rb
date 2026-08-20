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
#   MalformedUuidArg — a junk listing_id on edit_listing/close_listing is a
#                      typed 400 with no SQL internals on the wire — never a 500
#   MissingAuth      — a request with no Authorization → 401
#   GarbageToken     — an unparseable bearer token → 401
#   UnknownQuery     — an unregistered query name → 404
#   UnknownAction    — an unregistered action name → 404
#   OutOfEnumFilterIsNotSilentlyReinterpreted — a browse_listings `status`
#                      outside open|closed is a typed 400 naming the two,
#                      NEVER a 200 answering a different question (T-090)
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3006 KIOSK_ISSUER=http://127.0.0.1:3006 \
#   bundle exec ruby script/redteam_suite.rb
#
# Exits 0 when every scenario is BLOCKED (0 BREACH); exits 1 on any BREACH.
# A BREACH = a real hole in philslist — fix the app, not the scenario.

require "json"
require "net/http"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

ALICE_UUID = "00000000-0000-0000-0000-000000000001"
BOB_UUID   = "00000000-0000-0000-0000-000000000002"
# The agent id is a UUID, not a readable slug: `kiosk.action_log.agent_id`,
# every `kiosk.*_mandates.agent_id` and `kiosk.current_agent_id()` are all typed
# `uuid` in the canonical schema, so a stub identity carrying anything else is one
# the shipped tables cannot store (T-088 found it by being the first writer to try).
AGENT_A    = "a0000000-0000-0000-0000-000000000001"
AGENT_B    = "a0000000-0000-0000-0000-000000000002"
TOKEN_A    = "agent:u-#{ALICE_UUID}:a-#{AGENT_A}:r-customer"
TOKEN_B    = "agent:u-#{BOB_UUID}:a-#{AGENT_B}:r-customer"

# THE 0.4 WIRE. An action is `POST <endpoint>/<action-name>` carrying its
# arguments as the JSON body; a query is `GET <endpoint>/<query-name>` carrying
# them in the query string. A success body IS the result; an error is an RFC
# 9457 problem document whose branch point is the TOP-LEVEL `code`.
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

# ── Fixture: Alice posts a listing (target for cross-owner probes) ────────────
rc, alice_post = post_json("/kiosk/post_listing",
                           { category_slug: "furniture",
                             title: "Redteam target", body: "Alice's listing" },
                           bearer(TOKEN_A))
abort "A post_listing failed (#{rc}): #{JSON.generate(alice_post)} — run rake demo:setup" unless rc == 200
alice_listing_id = alice_post["listing_id"]
abort "no listing_id from A's post: #{JSON.generate(alice_post)}" unless alice_listing_id

# ── CrossTenantRead — Bob must not see Alice's listing in my_listings ─────────
rc, b_mine = get_json("/kiosk/my_listings", {}, bearer(TOKEN_B))
b_ids = Array(b_mine).map { |r| r["listing_id"] }
record(results, "CrossTenantRead",
       rc == 200 && !b_ids.include?(alice_listing_id),
       "Bob's my_listings #{b_ids.inspect} excludes Alice's #{alice_listing_id}")

# ── ForgedUserId — Bob posts with a forged owner_id (Alice's) ────────────────
#
# THIS BEAT CHANGED SHAPE AT 0.4 AND GOT STRONGER, so it is worth saying what
# it now proves. Through 0.3 the forged argument was ACCEPTED by the wire and
# IGNORED by the handler, and the proof was indirect: the created listing did
# not surface in Alice's my_listings. On the 0.4 wire `input_schema` is
# validated on every call and `post_listing` declares
# `additionalProperties: false` — the principal is not one of its inputs — so
# the forgery is REFUSED before the handler runs, with a typed 400 naming the
# offending parameter. Both halves are asserted: the wire refuses it, AND
# nothing belonging to Bob appears under Alice.
rc, forged = post_json("/kiosk/post_listing",
                       { category_slug: "free",
                         title: "Forged", body: "should be Bob's", owner_id: ALICE_UUID },
                       bearer(TOKEN_B))
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("owner_id")

# And the principal really does come from the token, not from anything the
# caller sent: Bob's LEGITIMATE listing lands under Bob and never under Alice.
rc_b, bobs = post_json("/kiosk/post_listing",
                       { category_slug: "free", title: "Bob's own", body: "belongs to Bob" },
                       bearer(TOKEN_B))
bob_id = bobs["listing_id"]
rc_a, a_mine = get_json("/kiosk/my_listings", {}, bearer(TOKEN_A))
a_ids = Array(a_mine).map { |r| r["listing_id"] }
record(results, "ForgedUserId",
       refused && rc_b == 200 && rc_a == 200 && !a_ids.include?(bob_id),
       "forged owner_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming owner_id); " \
       "Alice's list #{a_ids.inspect} excludes Bob's #{bob_id.inspect}")

# ── CrossOwnerEdit — Bob edits Alice's listing → 403 ─────────────────────────
rc, _ = post_json("/kiosk/edit_listing",
                  { listing_id: alice_listing_id, price_text: "€1" },
                  bearer(TOKEN_B))
record(results, "CrossOwnerEdit", rc == 403, "Bob edit Alice's listing → #{rc} (want 403)")

# ── CrossOwnerClose — Bob closes Alice's listing → 403 ───────────────────────
rc, _ = post_json("/kiosk/close_listing",
                  { listing_id: alice_listing_id },
                  bearer(TOKEN_B))
record(results, "CrossOwnerClose", rc == 403, "Bob close Alice's listing → #{rc} (want 403)")

# ── MalformedUuidArg — a junk listing_id must be a typed 400, never a 500 ────
# K-581/K-582: edit_listing and close_listing cast their listing_id `::uuid`.
# Before the UuidCheck guard, a malformed value made Postgres raise
# InvalidTextRepresentation, which is not a Kiosk error and escaped as a raw 500
# carrying the PG message. Three properties are asserted, not one: the status is
# 400 (a client mistake reported as such), the problem document's top-level
# `code` is the typed `bad_request` an assistant can branch on, and NO SQL
# internals reach the wire.
MALFORMED_IDS = ["not-a-uuid", "1; DROP TABLE listings", "", "  "].freeze
SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

uuid_probes = %w[edit_listing close_listing].flat_map do |verb|
  MALFORMED_IDS.map do |junk|
    rc, body = post_json("/kiosk/#{verb}", { listing_id: junk }, bearer(TOKEN_A))
    leak = SQL_INTERNALS.find { |needle| JSON.generate(body).include?(needle) }
    ok = rc == 400 && body["code"] == "bad_request" && leak.nil?
    [ok, "#{verb}(#{junk.inspect})→#{rc}/#{body['code'].inspect}#{leak ? " LEAK #{leak}" : ''}"]
  end
end
record(results, "MalformedUuidArg", uuid_probes.all? { |ok, _| ok },
       "malformed listing_id → #{uuid_probes.map(&:last).join(', ')} " \
       "(want 400/\"bad_request\" and no SQL internals)")

# ── MissingAuth — no Authorization header → 401 ──────────────────────────────
rc, _ = get_json("/kiosk/browse_listings")
record(results, "MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

# ── GarbageToken — unparseable bearer → 401 ──────────────────────────────────
rc, _ = get_json("/kiosk/browse_listings", {}, bearer("not-a-real-token"))
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
  rc, body = post_json("/kiosk/#{name}", { name: "browse_listings" }, bearer(TOKEN_A))
  [rc == 404 && body["code"] == "not_found", "#{name}→#{rc}/#{body['code'].inspect}"]
end
record(results, "RetiredWire", retired.all? { |ok, _| ok },
       "0.3 endpoints #{retired.map(&:last).join(', ')} (want 404/\"not_found\")")

# ── MethodMismatch — a GET at an action's path is 405, never a silent 404 ────
# The resource EXISTS; answering 404 would be a lie about it, and a caller that
# read 404 as "this operator cannot do that" would give up on a verb it could
# have called correctly.
uri405 = URI("#{SERVER}/kiosk/post_listing")
res405 = Net::HTTP.new(uri405.host, uri405.port)
              .request(Net::HTTP::Get.new(uri405, bearer(TOKEN_A)))
body405 = (JSON.parse(res405.body) rescue {})
record(results, "MethodMismatch",
       res405.code.to_i == 405 && body405["code"] == "method_not_allowed" &&
         res405["allow"].to_s.upcase.include?("POST"),
       "GET an action → #{res405.code}/#{body405['code'].inspect} Allow=#{res405['allow'].inspect} " \
       "(want 405/\"method_not_allowed\"/POST)")

# ── OutOfEnumFilterIsNotSilentlyReinterpreted (T-090) ────────────────────────
#
# THE WORST OF THE FOUR CASES T-090's SURVEY FOUND, and the reason it is in the
# ADVERSARIAL battery rather than in a flow test. `browse_listings` used to run
# `status = "open" unless Listing::STATUSES.include?(status)` — so
# `status=deleted` came back 200 with the OPEN board. Not an empty list: a
# successful-looking answer to a DIFFERENT QUESTION, with nothing in the
# response saying the filter had been discarded. An assistant relaying it told
# its human "here are the deleted listings" and was confidently wrong, which is
# a worse failure than any refusal.
#
# The clamp is deleted and nothing replaced it: `status` declares
# `enum: [open, closed]` and `input_schema` is validated on every per-verb call
# (spec §8.1 item 5), so the schema layer refuses first and NAMES both values —
# spec §9.1's first branch falling out of a declaration.
#
# The positive control is what keeps this honest: `status=closed` must still be
# ANSWERED (200), or a handler that refused everything would pass.
rc_bad, bad_status = get_json("/kiosk/browse_listings", { status: "deleted" }, bearer(TOKEN_A))
detail_bad = bad_status.is_a?(Hash) ? bad_status["detail"].to_s : ""
rc_ctl, ctl_rows = get_json("/kiosk/browse_listings", { status: "closed" }, bearer(TOKEN_A))
record(results, "OutOfEnumFilterIsNotSilentlyReinterpreted",
       rc_bad == 400 && bad_status["code"] == "bad_request" &&
         detail_bad.include?("open") && detail_bad.include?("closed") &&
         rc_ctl == 200 && ctl_rows.is_a?(Array),
       "status=deleted → #{rc_bad}/#{bad_status['code'].inspect} detail=#{detail_bad[0, 120].inspect}; " \
       "CONTROL status=closed → #{rc_ctl}/#{ctl_rows.is_a?(Array) ? "array" : ctl_rows.class} " \
       "(want 400 bad_request naming open and closed, and an ANSWERED control)")

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
