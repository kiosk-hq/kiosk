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
#                      resolves to NO identity, in EVERY environment, while a
#                      genuinely-bound token is answered
#   UnknownQuery     — an unregistered query name → 404
#   UnknownAction    — an unregistered action name → 404
#   UnregisteredVerbIsOrdinaryRefusal — `POST /kiosk/query` and
#                      `POST /kiosk/run` name no registered verb, so they
#                      answer the ordinary 404 an authenticated caller gets,
#                      and 401 without a bearer; no privileged endpoint hides
#                      behind a generic-sounding word
#   MethodMismatch   — a GET at an action’s path is 405 + `Allow: POST`, never
#                      a silent 404
#   OutOfEnumFilterIsNotSilentlyReinterpreted — a browse_listings
#                      `category_slug` outside the LIVE `categories` table is a
#                      typed 400 naming the sections that exist, NEVER a 200
#                      answering a different question
#   LikeMetacharactersAreEscaped — a browse_listings `keyword` carrying LIKE
#                      metacharacters matches them LITERALLY: `_` and `%` are
#                      not live wildcards, so a search is never answered a
#                      WIDER question than it asked
#   NoSellerPiiOnTheOpenBoard — the cross-owner board names sellers by an
#                      opaque, per-seller pseudonym and carries no account
#                      address anywhere in the response
#   DeviceGrantRoleSelfSelection (from `kiosk-redteam`, shared by every demo) —
#     the account-binding claim ceremony's UNAUTHENTICATED opening request
#     refuses `role`/`scope` at a DECLARED value as well as an invented one,
#     while the role-less request still opens the ceremony
#
# THE TWO PRINCIPALS ARE EARNED, NOT ASSERTED. Alice and Bob are bound
# through the shipped ceremony — Equihash-tolled `/auth/register` → the human's
# real Devise sign-in → `/auth/link` → `/auth/claim` (script/bound_assistant.rb) —
# because nothing turns a written-down `agent:u-…:a-…:r-…` string into an
# identity: the ceremony is the only way to hold a principal here. That is also
# why the SelfAssertedTokenForgery beat below is an ordinary over-the-wire
# attack in the SAME environment this suite drives.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3006 KIOSK_ISSUER=http://127.0.0.1:3006 \
#   ALICE_EMAIL=alice@example.com BOB_EMAIL=bob@example.com \
#   DEMO_PASSWORD=… bundle exec ruby script/redteam_suite.rb
#
# Exits 0 when every scenario is BLOCKED (0 BREACH); exits 1 on any BREACH, and
# on a battery that produced no proofs at all; exits 2 when a beat could not be
# exercised and was not expected to skip.
# A BREACH = a real hole in philslist — fix the app, not the scenario.

require "json"
require "securerandom"

# The shared harness: the wire this battery attacks over, the ledger it files
# its verdicts into, the leak oracle its hostile-input beats ask, and the one
# library beat further down. Everything in this file that is not about
# philslist is the gem's.
require "kiosk/redteam"

require_relative "bound_assistant"

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
WIRE = Kiosk::Redteam::Wire.new(base_url: SERVER)

# One ledger for every beat below — the hand-written ones about philslist's own
# verbs and the library one about the ceremony every origin serves — printed in
# one vocabulary and answered by one exit status.
BATTERY = Kiosk::Redteam::Battery.new

# ── Fixture: two principals, each EARNED through the shipped ceremony ─────────
ALICE = bind_assistant(server: SERVER, issuer: ISSUER, email: ALICE_EMAIL, password: PASSWORD)
BOB   = bind_assistant(server: SERVER, issuer: ISSUER, email: BOB_EMAIL,   password: PASSWORD)
abort "both assistants bound to the SAME account (#{ALICE.user_id}) — no boundary to attack" \
  if ALICE.user_id == BOB.user_id

# ── Fixture: Alice posts a listing (target for cross-owner probes) ────────────
rc, alice_post = WIRE.post_json("/kiosk/post_listing",
                                { category_slug: "furniture",
                                  title: "Redteam target", body: "Alice's listing" },
                                ALICE.bearer)
abort "A post_listing failed (#{rc}): #{JSON.generate(alice_post)} — run rake demo:setup" unless rc == 200
alice_listing_id = alice_post["listing_id"]
abort "no listing_id from A's post: #{JSON.generate(alice_post)}" unless alice_listing_id

# ── CrossTenantRead — Bob must not see Alice's listing in my_listings ─────────
rc, b_mine = WIRE.get_json("/kiosk/my_listings", {}, BOB.bearer)
b_ids = Array(b_mine).map { |r| r["listing_id"] }
BATTERY.record("CrossTenantRead",
               rc == 200 && !b_ids.include?(alice_listing_id),
               "Bob's my_listings #{b_ids.inspect} excludes Alice's #{alice_listing_id}")

# ── ForgedUserId — Bob posts with a forged owner_id (Alice's) ────────────────
#
# WHAT THIS BEAT PROVES. `input_schema` is validated on every call and
# `post_listing` declares `additionalProperties: false` — the principal is not
# one of its inputs — so the forgery is REFUSED before the handler runs, with a
# typed 400 naming the offending parameter. Both halves are asserted: the wire
# refuses it, AND nothing belonging to Bob appears under Alice.
rc, forged = WIRE.post_json("/kiosk/post_listing",
                            { category_slug: "free",
                              title: "Forged", body: "should be Bob's", owner_id: ALICE.user_id },
                            BOB.bearer)
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("owner_id")

# And the principal really does come from the token, not from anything the
# caller sent: Bob's LEGITIMATE listing lands under Bob and never under Alice.
rc_b, bobs = WIRE.post_json("/kiosk/post_listing",
                            { category_slug: "free", title: "Bob's own", body: "belongs to Bob" },
                            BOB.bearer)
bob_id = bobs["listing_id"]
rc_a, a_mine = WIRE.get_json("/kiosk/my_listings", {}, ALICE.bearer)
a_ids = Array(a_mine).map { |r| r["listing_id"] }
BATTERY.record("ForgedUserId",
               refused && rc_b == 200 && rc_a == 200 && !a_ids.include?(bob_id),
               "forged owner_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming owner_id); " \
               "Alice's list #{a_ids.inspect} excludes Bob's #{bob_id.inspect}")

# ── CrossOwnerEdit — Bob edits Alice's listing → 403 ─────────────────────────
rc, _ = WIRE.post_json("/kiosk/edit_listing",
                       { listing_id: alice_listing_id, price_text: "€1" },
                       BOB.bearer)
BATTERY.record("CrossOwnerEdit", rc == 403, "Bob edit Alice's listing → #{rc} (want 403)")

# ── CrossOwnerClose — Bob closes Alice's listing → 403 ───────────────────────
rc, _ = WIRE.post_json("/kiosk/close_listing",
                       { listing_id: alice_listing_id },
                       BOB.bearer)
BATTERY.record("CrossOwnerClose", rc == 403, "Bob close Alice's listing → #{rc} (want 403)")

# ── MalformedUuidArg — a junk listing_id must be a typed 400, never a 500 ────
# edit_listing and close_listing cast their listing_id `::uuid`. Without the
# Kiosk::UuidCheck guard a malformed value makes Postgres raise
# InvalidTextRepresentation, which is not a Kiosk error and escapes as a raw 500
# carrying the PG message. Three properties are asserted, not one: the status is
# 400 (a client mistake reported as such), the problem document's top-level
# `code` is the typed `bad_request` an assistant can branch on, and NO SQL
# internals reach the wire.
MALFORMED_IDS = ["not-a-uuid", "1; DROP TABLE listings", "", "  "].freeze
SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

# THE SCAN IS TOLD WHAT THIS PROBE SENT. philslist answers a bad
# argument by NAMING the value it got — `listing_id "…" is not a uuid`, and
# `unknown category_slug …` on the write path — so the bytes searched for
# SQL_INTERNALS are partly the probe's own. Without `supplied:` a junk id
# spelling `PG::` would be reported as a BREACH on its own echo, under a runner
# whose prose says a BREACH means "fix the app, not the scenario".
# {Kiosk::Redteam::LeakScan} discounts a needle only where those exact bytes lie
# inside one contiguous run the probe supplied — not a blind `gsub`, which could
# erase a real leak instead.
uuid_probes = %w[edit_listing close_listing].flat_map do |verb|
  MALFORMED_IDS.map do |junk|
    args     = { listing_id: junk }
    rc, body = WIRE.post_json("/kiosk/#{verb}", args, ALICE.bearer)
    scan = Kiosk::Redteam::LeakScan.scan(body, SQL_INTERNALS, supplied: args)
    ok = rc == 400 && body["code"] == "bad_request" && !scan.leak?
    [ok, "#{verb}(#{junk.inspect})→#{rc}/#{body['code'].inspect}" \
         "#{scan.leak ? " LEAK #{scan.leak}" : ''}#{scan.note}"]
  end
end
BATTERY.record("MalformedUuidArg", uuid_probes.all? { |ok, _| ok },
               "malformed listing_id → #{uuid_probes.map(&:last).join(', ')} " \
               "(want 400/\"bad_request\" and no SQL internals)")

# ── MissingAuth — no Authorization header → 401 ──────────────────────────────
rc, _ = WIRE.get_json("/kiosk/browse_listings")
BATTERY.record("MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

# ── GarbageToken — unparseable bearer → 401 ──────────────────────────────────
rc, _ = WIRE.get_json("/kiosk/browse_listings", {}, WIRE.bearer("not-a-real-token"))
BATTERY.record("GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# ── SelfAssertedTokenForgery — OVER THE LIVE WIRE ────────────────────────────
#
# NOTHING ANYWHERE PARSES A SELF-ASSERTED BEARER. `c.agent_idp` is unset, so the
# engine's own DefaultAgentIdp verifies the kiosk-pop JWTs it minted and nothing
# else — in every environment, with no env gate holding the line. So this beat
# is an ordinary over-the-wire probe in the SAME environment this suite drives,
# which is a strictly stronger claim than one an env gate could support.
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
forged_bearer = WIRE.bearer("agent:u-#{ALICE.user_id}:a-#{SecureRandom.uuid}:r-owner")
rc_forged_read, = WIRE.get_json("/kiosk/my_listings", {}, forged_bearer)
rc_forged_write, = WIRE.post_json("/kiosk/post_listing",
                                  { category_slug: "free", title: "Self-asserted", body: "must never exist" },
                                  forged_bearer)
rc_real_read,  = WIRE.get_json("/kiosk/my_listings", {}, ALICE.bearer)
rc_real_write, = WIRE.post_json("/kiosk/post_listing",
                                { category_slug: "free", title: "Really Alice's", body: "bound token" },
                                ALICE.bearer)
BATTERY.record("SelfAssertedTokenForgery",
               rc_forged_read == 401 && rc_forged_write == 401 &&
                 rc_real_read == 200 && rc_real_write == 200,
               "self-asserted `agent:u-…:a-…:r-owner` naming a real account → read #{rc_forged_read}, " \
               "write #{rc_forged_write} (want 401/401: it resolves to NO identity, in THIS environment — " \
               "no env gate involved); CONTROL Alice's genuinely-bound token → read #{rc_real_read}, " \
               "write #{rc_real_write} (want 200/200, so the refusal is not vacuous)")

# ── UnknownQuery — unregistered query name → 404 ─────────────────────────────
rc, _ = WIRE.get_json("/kiosk/frobnicate", {}, ALICE.bearer)
BATTERY.record("UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = WIRE.post_json("/kiosk/nope", {}, ALICE.bearer)
BATTERY.record("UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── UnregisteredVerbIsOrdinaryRefusal — a path naming no verb is refused ─────
# `POST /kiosk/query` and `POST /kiosk/run` reach the per-verb controller as
# verbs literally named "query" and "run", which nobody registered, so they
# answer the ordinary 404 an AUTHENTICATED caller gets — no privileged
# endpoint behind a generic-sounding word, and no second conformance surface
# to attack. Those two names are what a caller hunting for a multiplexed
# endpoint tries first, which is why the beat dials them rather than a
# nonsense word.
#
# BOTH CALLERS ARE PROBED, and that is the whole point of the qualifier above.
# `VerbController#serve` resolves the identity BEFORE it looks the verb up, so a
# caller with no bearer never reaches the registry lookup that produces the 404 —
# it is answered 401 `unauthenticated`, exactly as it would be at any other name.
# A beat that dialled only WITH a bearer would let prose say the 404 flatly while
# nothing tested the anonymous case.
#
# The 404's code is `verb_not_found`, not `not_found`: `query` and `run` are
# NAMES nobody registered, and the vocabulary reserves `not_found` for an
# argument that ADDRESSED something absent.
unregistered = %w[query run].map do |name|
  rc, body = WIRE.post_json("/kiosk/#{name}", { name: "browse_listings" }, ALICE.bearer)
  [rc == 404 && body["code"] == "verb_not_found", "#{name}→#{rc}/#{body['code'].inspect}"]
end
unregistered_anon = %w[query run].map do |name|
  rc, body = WIRE.post_json("/kiosk/#{name}", { name: "browse_listings" })
  [rc == 401 && body["code"] == "unauthenticated", "#{name}(anon)→#{rc}/#{body['code'].inspect}"]
end
BATTERY.record("UnregisteredVerbIsOrdinaryRefusal",
               (unregistered + unregistered_anon).all? { |ok, _| ok },
               "unregistered verb names #{(unregistered + unregistered_anon).map(&:last).join(', ')} " \
               "(want 404/\"verb_not_found\" with a bearer, 401/\"unauthenticated\" without)")

# ── MethodMismatch — a GET at an action's path is 405, never a silent 404 ────
# The resource EXISTS; answering 404 would be a lie about it, and a caller that
# read 404 as "this operator cannot do that" would give up on a verb it could
# have called correctly.
res405 = WIRE.request(:get, "/kiosk/post_listing", headers: ALICE.bearer)
BATTERY.record("MethodMismatch",
               res405.status == 405 && res405.body["code"] == "method_not_allowed" &&
                 res405["allow"].to_s.upcase.include?("POST"),
               "GET an action → #{res405.status}/#{res405.body['code'].inspect} " \
               "Allow=#{res405['allow'].inspect} (want 405/\"method_not_allowed\"/POST)")

# ── OutOfEnumFilterIsNotSilentlyReinterpreted ────────────────────────────────
#
# THE WORST SHAPE AN OUT-OF-ENUM FILTER CAN TAKE, and the reason it is in the
# ADVERSARIAL battery rather than in a flow test. A handler that clamps an
# unknown filter value back to its default — `status = "open" unless
# Listing::STATUSES.include?(status)` — answers `status=deleted` with 200 and
# the OPEN board. Not an empty list: a successful-looking answer to a DIFFERENT
# QUESTION, with nothing in the response saying the filter had been discarded.
# An assistant relaying it tells its human "here are the deleted listings" and
# is confidently wrong, which is a worse failure than any refusal.
#
# THE SUBJECT MOVED, THE PROPERTY DID NOT. `status` is not a parameter of this
# verb: on an open board a status knob is not merely useless but harmful. So the
# beat drives the filter that IS there — `category_slug`, whose domain is the
# LIVE `categories` table, declared as a proc. That makes this the stronger
# test: it asserts the refusal AND that the refusal names the sections the
# database currently holds, which is the whole point of deriving an enum from
# data instead of freezing it in code.
#
# The positive control is what keeps it honest: a real section must still be
# ANSWERED (200), or a handler that refused everything would pass.
rc_bad, bad_status = WIRE.get_json("/kiosk/browse_listings", { category_slug: "no-such-section" }, ALICE.bearer)
detail_bad = bad_status.is_a?(Hash) ? bad_status["detail"].to_s : ""
rc_ctl, ctl_rows = WIRE.get_json("/kiosk/browse_listings", { category_slug: "bikes" }, ALICE.bearer)
BATTERY.record("OutOfEnumFilterIsNotSilentlyReinterpreted",
               rc_bad == 400 && bad_status["code"] == "bad_request" &&
                 detail_bad.include?("bikes") && detail_bad.include?("housing") &&
                 rc_ctl == 200 && ctl_rows.is_a?(Array),
               "category_slug=no-such-section → #{rc_bad}/#{bad_status['code'].inspect} " \
               "detail=#{detail_bad[0, 160].inspect}; " \
               "CONTROL category_slug=bikes → #{rc_ctl}/#{ctl_rows.is_a?(Array) ? "array" : ctl_rows.class} " \
               "(want 400 bad_request naming the LIVE categories, and an ANSWERED control)")

# ── LikeMetacharactersAreEscaped ─────────────────────────────────────────────
#
# NOT an injection test — record that, because the shape invites the misfiling.
# Arel's `matches` inlines an ADAPTER-QUOTED literal, so a structural payload
# lands inside the string with the table intact; that was measured. What was
# real is that `_` and `%` reached Postgres as LIVE WILDCARDS, so a human
# searching "50% off" was answered a different question — the same failure the
# beat above exists for, arriving through the escaping layer instead of a
# clamp. `sanitize_sql_like` closes it, and the assertion is behavioural: an
# underscore must match an UNDERSCORE.
#
# The control is a keyword that DOES match, so a handler that returned nothing
# for everything could not pass.
_, wild_rows = WIRE.get_json("/kiosk/browse_listings", { keyword: "b_ke" }, ALICE.bearer)
rc_lit, lit_rows = WIRE.get_json("/kiosk/browse_listings", { keyword: "bike" }, ALICE.bearer)
BATTERY.record("LikeMetacharactersAreEscaped",
               wild_rows.is_a?(Array) && wild_rows.empty? &&
                 rc_lit == 200 && lit_rows.is_a?(Array) && !lit_rows.empty?,
               "keyword=b_ke → #{wild_rows.is_a?(Array) ? "#{wild_rows.length} rows" : wild_rows.class}; " \
               "CONTROL keyword=bike → #{rc_lit}/#{lit_rows.is_a?(Array) ? "#{lit_rows.length} rows" : lit_rows.class} " \
               "(want 0 rows for the escaped wildcard and a non-empty control)")

# ── NoSellerPiiOnTheOpenBoard ────────────────────────────────────────────────
#
# THE ONE BEAT THAT HAS TO SURVIVE A REFACTOR. `browse_listings` is deliberately
# cross-owner — every authenticated principal sees every open listing — so
# whatever the seller column holds is published to anyone who can complete
# `/auth/register`, for every account that has ever posted. It held
# `users.email`, which meant a self-registered assistant walked away with the
# address of every account holder in the seed. The projection is one `pluck`
# line; nothing but an assertion stops a future edit from putting the column
# back, which is why this is a battery scenario and not a comment.
#
# THE PROBE RUNS AS BOB, deliberately, and reads ALICE's rows: this is exactly
# the attacker's position — an assistant bound to one account, reading the open
# board for what it discloses about the others.
#
# Three things are asserted, and the second and third are what make the first
# non-vacuous:
#   1. NO account address anywhere in the response. Both seeded addresses are
#      searched for in the RAW BODY, not in `owner_handle` — a leak that moved
#      to another field, or into a debug key, is the same leak.
#   2. Every row's `owner_handle` is a `seller-` pseudonym and contains no `@`.
#      A handler that dropped the field entirely would fail here, so the beat
#      cannot be passed by publishing nothing.
#   3. The handle is PER-SELLER: Alice's rows all share ONE handle and Bob's
#      differs from it. That pins the accepted tradeoff (a buyer can tell two
#      listings are one seller) so a later switch to a per-listing or
#      per-request value is caught rather than silently shipped.
rc_board, board_rows = WIRE.get_json("/kiosk/browse_listings", {}, BOB.bearer)
raw_board = JSON.generate(board_rows)
rows          = board_rows.is_a?(Array) ? board_rows : []
handles       = rows.map { |r| r["owner_handle"] }
alice_handle  = rows.find { |r| r["listing_id"] == alice_listing_id }&.fetch("owner_handle", nil)
bob_handle    = rows.find { |r| r["listing_id"] == bob_id }&.fetch("owner_handle", nil)
alice_rows    = rows.count { |r| r["owner_handle"] == alice_handle }
no_addresses  = !raw_board.include?(ALICE_EMAIL) && !raw_board.include?(BOB_EMAIL) && !raw_board.include?("@example.com")
well_formed   = !handles.empty? && handles.all? { |h| h.is_a?(String) && h.match?(/\Aseller-[0-9a-f]{12}\z/) }
# Alice's seeded listings AND her redteam target must read under ONE handle
# (>= 2 rows), and Bob's must not be that handle.
per_seller    = !alice_handle.nil? && !bob_handle.nil? &&
                alice_handle != bob_handle && alice_rows >= 2
BATTERY.record("NoSellerPiiOnTheOpenBoard",
               rc_board == 200 && no_addresses && well_formed && per_seller,
               "browse_listings as BOB → #{rc_board}, #{rows.length} rows, " \
               "#{handles.uniq.length} distinct handles #{handles.uniq.first(3).inspect}; " \
               "account addresses in body: #{no_addresses ? 'none' : 'FOUND'}; " \
               "alice=#{alice_handle.inspect} on #{alice_rows} rows, bob=#{bob_handle.inspect} " \
               "(want 200, no account address anywhere, every handle an opaque " \
               "`seller-<12 hex>`, and ONE handle covering >= 2 of Alice's rows and not Bob's)")

# ── DeviceGrantRoleSelfSelection — the SHARED framework beat ─────────────────
#
# The one beat in this file that is NOT hand-rolled: it comes from
# `kiosk-redteam`, so every demo runs the SAME assertion about the
# account-binding claim ceremony and a demo cannot be left out of it by
# forgetting to copy a block.
#
# It exists because the coverage for role self-selection rested on a condition
# nobody re-measured: the shared `PrivilegeSelfSelection` scenario probes
# `/auth/register` only, and the ceremony beats lived in ONE demo's suite. The
# other six were safe purely because each declares a single role — a mitigation
# that expires unnoticed the day a demo declares a second one.
#
# `declared_roles` names what `config/initializers/kiosk.rb` declares here. The
# scenario ALSO derives a declared role from the wire (the `role` claim of a
# token this origin mints at registration), so a stale list weakens the probe
# rather than emptying it — an invented role was refused by the vulnerable code
# too, which is why a probe that names only one cannot fail.
# `on_skip: :breach` on purpose: this origin declares a role, so "could not
# test" is a failure of the harness rather than a property of the provider, and
# a silent third state is what let the last one hide.
BATTERY.scenario(
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  client:  Kiosk::Redteam::Client.new(base_url: SERVER),
  profile: Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer]),
  on_skip: :breach,
)

# ── Verdict ──────────────────────────────────────────────────────────────────
# The gem answers it: 0 only when at least one attack ran and every attack that
# ran was blocked, 1 on a breach or on a battery that proved nothing, 2 when a
# beat skipped that this origin was not expected to skip. philslist expects no
# skips at all — every beat above is about a surface it has.
exit BATTERY.report!
