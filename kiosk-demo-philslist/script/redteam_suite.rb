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
#   SelfAssertedTokenForgery — a self-asserted `agent:u-…:a-…:r-owner` bearer
#                      resolves to NO identity, in EVERY environment (K-539 /
#                      T-104), while a genuinely-bound token is answered
#   UnknownQuery     — an unregistered query name → 404
#   UnknownAction    — an unregistered action name → 404
#   OutOfEnumFilterIsNotSilentlyReinterpreted — a browse_listings `status`
#                      outside open|closed is a typed 400 naming the two,
#                      NEVER a 200 answering a different question (T-090)
#
# THE TWO PRINCIPALS ARE EARNED, NOT ASSERTED (T-104). Alice and Bob are bound
# through the shipped ceremony — Equihash-tolled `/auth/register` → the human's
# real Devise sign-in → `/auth/link` → `/auth/claim` (lib/bound_assistant.rb) —
# because the dev-only parser that used to turn a written-down
# `agent:u-…:a-…:r-…` string into an identity at any role is deleted. That is
# also what promotes the SelfAssertedTokenForgery beat below from an in-process
# probe under a stubbed production config into an ordinary over-the-wire attack
# in the SAME environment this suite drives.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3006 KIOSK_ISSUER=http://127.0.0.1:3006 \
#   ALICE_EMAIL=alice@example.com BOB_EMAIL=bob@example.com \
#   DEMO_PASSWORD=… bundle exec ruby script/redteam_suite.rb
#
# Exits 0 when every scenario is BLOCKED (0 BREACH); exits 1 on any BREACH.
# A BREACH = a real hole in philslist — fix the app, not the scenario.

require "json"
require "net/http"
require "securerandom"
require "uri"

require_relative "../lib/bound_assistant"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER", SERVER)

# The seeded humans behind the two assistants (db/seeds.rb). Credentials arrive
# in the environment from the rake task, the way demo:binding's HOLDER_EMAIL /
# HOLDER_PASSWORD do — never as literals in a driver.
ALICE_EMAIL = ENV.fetch("ALICE_EMAIL")
BOB_EMAIL   = ENV.fetch("BOB_EMAIL")
PASSWORD    = ENV.fetch("DEMO_PASSWORD")

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

# ── Fixture: two principals, each EARNED through the shipped ceremony ─────────
ALICE = bind_assistant(server: SERVER, issuer: ISSUER, email: ALICE_EMAIL, password: PASSWORD)
BOB   = bind_assistant(server: SERVER, issuer: ISSUER, email: BOB_EMAIL,   password: PASSWORD)
abort "both assistants bound to the SAME account (#{ALICE.user_id}) — no boundary to attack" \
  if ALICE.user_id == BOB.user_id

# ── Fixture: Alice posts a listing (target for cross-owner probes) ────────────
rc, alice_post = post_json("/kiosk/post_listing",
                           { category_slug: "furniture",
                             title: "Redteam target", body: "Alice's listing" },
                           ALICE.bearer)
abort "A post_listing failed (#{rc}): #{JSON.generate(alice_post)} — run rake demo:setup" unless rc == 200
alice_listing_id = alice_post["listing_id"]
abort "no listing_id from A's post: #{JSON.generate(alice_post)}" unless alice_listing_id

# ── CrossTenantRead — Bob must not see Alice's listing in my_listings ─────────
rc, b_mine = get_json("/kiosk/my_listings", {}, BOB.bearer)
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
                         title: "Forged", body: "should be Bob's", owner_id: ALICE.user_id },
                       BOB.bearer)
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("owner_id")

# And the principal really does come from the token, not from anything the
# caller sent: Bob's LEGITIMATE listing lands under Bob and never under Alice.
rc_b, bobs = post_json("/kiosk/post_listing",
                       { category_slug: "free", title: "Bob's own", body: "belongs to Bob" },
                       BOB.bearer)
bob_id = bobs["listing_id"]
rc_a, a_mine = get_json("/kiosk/my_listings", {}, ALICE.bearer)
a_ids = Array(a_mine).map { |r| r["listing_id"] }
record(results, "ForgedUserId",
       refused && rc_b == 200 && rc_a == 200 && !a_ids.include?(bob_id),
       "forged owner_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming owner_id); " \
       "Alice's list #{a_ids.inspect} excludes Bob's #{bob_id.inspect}")

# ── CrossOwnerEdit — Bob edits Alice's listing → 403 ─────────────────────────
rc, _ = post_json("/kiosk/edit_listing",
                  { listing_id: alice_listing_id, price_text: "€1" },
                  BOB.bearer)
record(results, "CrossOwnerEdit", rc == 403, "Bob edit Alice's listing → #{rc} (want 403)")

# ── CrossOwnerClose — Bob closes Alice's listing → 403 ───────────────────────
rc, _ = post_json("/kiosk/close_listing",
                  { listing_id: alice_listing_id },
                  BOB.bearer)
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
    rc, body = post_json("/kiosk/#{verb}", { listing_id: junk }, ALICE.bearer)
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

# ── SelfAssertedTokenForgery (K-539 / T-104) — OVER THE LIVE WIRE ─────────────
#
# THE BEAT CHANGED SHAPE, AND THE CHANGE IS THE POINT. philslist used to compose
# a hand-copied agent-IdP that parsed a self-asserted, UNSIGNED
# `agent:u-<user>:a-<agent>:r-<role>` bearer straight into an authenticated
# identity — at whatever role the string named. It was live in development on
# purpose (every driver in this repo, including this suite, held itself a
# principal that way), so the block could only ever be demonstrated IN-PROCESS
# against a stubbed production Rails.env, and an env gate was the whole defence.
#
# There is no such parser any more, in any environment: `c.agent_idp` is unset,
# so the engine's own DefaultAgentIdp verifies the kiosk-pop JWTs it minted and
# nothing else. So this is now an ordinary over-the-wire probe in the SAME
# environment this suite drives, which is a strictly stronger claim than the one
# an env gate could support.
#
# The forged string is deliberately maximal: it names a REAL account (Alice's,
# read off her genuinely-bound token, so nothing about it is stale), a
# syntactically valid uuid agent id, and `r-owner` — a role philslist does not
# even configure (`c.roles = %i[customer]`). It must buy nothing anywhere: not a
# read, not a write.
#
# The positive control is what keeps this honest. A suite where every bearer
# 401s would pass a refusal-only assertion, so the same verbs are called with
# Alice's REAL bound token and must be ANSWERED.
forged_bearer = bearer("agent:u-#{ALICE.user_id}:a-#{SecureRandom.uuid}:r-owner")
rc_forged_read, = get_json("/kiosk/my_listings", {}, forged_bearer)
rc_forged_write, = post_json("/kiosk/post_listing",
                             { category_slug: "free", title: "Self-asserted", body: "must never exist" },
                             forged_bearer)
rc_real_read,  = get_json("/kiosk/my_listings", {}, ALICE.bearer)
rc_real_write, = post_json("/kiosk/post_listing",
                           { category_slug: "free", title: "Really Alice's", body: "bound token" },
                           ALICE.bearer)
record(results, "SelfAssertedTokenForgery",
       rc_forged_read == 401 && rc_forged_write == 401 &&
         rc_real_read == 200 && rc_real_write == 200,
       "self-asserted `agent:u-…:a-…:r-owner` naming a real account → read #{rc_forged_read}, " \
       "write #{rc_forged_write} (want 401/401: it resolves to NO identity, in THIS environment — " \
       "no env gate involved); CONTROL Alice's genuinely-bound token → read #{rc_real_read}, " \
       "write #{rc_real_write} (want 200/200, so the refusal is not vacuous)")

# ── UnknownQuery — unregistered query name → 404 ─────────────────────────────
rc, _ = get_json("/kiosk/frobnicate", {}, ALICE.bearer)
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = post_json("/kiosk/nope", {}, ALICE.bearer)
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── RetiredWire — the deleted 0.3 endpoints are GONE, not tombstoned ─────────
# T-074 = A was a hard cut. `POST /kiosk/query` now reaches the per-verb
# controller as a verb literally named "query", which nobody registered, so it
# answers the ordinary 404 — no privileged endpoint, no compatibility payload,
# no second conformance surface to attack.
retired = %w[query run].map do |name|
  rc, body = post_json("/kiosk/#{name}", { name: "browse_listings" }, ALICE.bearer)
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
              .request(Net::HTTP::Get.new(uri405, ALICE.bearer))
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
rc_bad, bad_status = get_json("/kiosk/browse_listings", { status: "deleted" }, ALICE.bearer)
detail_bad = bad_status.is_a?(Hash) ? bad_status["detail"].to_s : ""
rc_ctl, ctl_rows = get_json("/kiosk/browse_listings", { status: "closed" }, ALICE.bearer)
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
