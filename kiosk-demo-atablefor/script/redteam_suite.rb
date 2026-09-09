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
#   CrossTenantRead   — Bea's my_bookings must NOT contain Diego's booking
#   ForgedUserId      — a forged user_id on book_table is REFUSED (400
#                       bad_request naming it), and Bea's legitimate booking
#                       never surfaces under Diego
#   CrossOwnerCancel  — Bea cancel_booking on Diego's booking → 403
#   MalformedUuidArg  — a junk booking_id on cancel_booking is a typed 400
#                       with no SQL internals on the wire — never a 500
#   RegisterWithoutPoP — register with no proof-of-possession JWS → not 201
#   MissingAuth       — a request with no Authorization → 401
#   GarbageToken      — an unparseable bearer token → 401
#   SelfAssertedTokenForgery — a self-asserted `agent:u-…:a-…:r-owner` bearer
#                       resolves to NO identity → 401, unconditionally and in
#                       THIS (development) environment: agent auth has no
#                       cleartext parser to fall back to
#   UnknownQuery      — an unregistered query name → 404
#   UnknownAction     — an unregistered action name → 404
#   UnregisteredVerbIsOrdinaryRefusal — `POST /kiosk/query` and
#                       `POST /kiosk/run` name no registered verb and no route
#                       draws them, so they answer the ordinary 404 any undrawn
#                       path gets, with or without a bearer; no privileged
#                       endpoint hides behind a generic-sounding word
#   MethodMismatch    — a GET at an action's path draws no route, so it is the
#                       same ordinary 404 and never serves the write
#   InvalidFilterIsNotAnEmptyList — an availability filter naming a seating
#     time, a date or a NEIGHBOURHOOD that does not exist is a typed 400
#     NAMING the valid values, never a 200 with an empty rows array and never
#     a 500
#   BookOutsideOfferedHorizon — book_table on a well-formed date OUTSIDE the
#     rolling horizon availability offers is a typed 400 NAMING the bookable
#     dates, never a confirmed booking for a seating that was never offered;
#     and the BASIC-form `YYYYMMDD` spelling, which is not the one any
#     availability row hands out, is refused by BOTH layers
#   HostileArgShapes — boolean/array/object/junk values on book_table's
#     party_size, restaurant_id, restaurant_table_id, date and time, on
#     availability's party_size (including the two bracket spellings) and on
#     cancel_booking's booking_id are a typed 400 with no runtime vocabulary on
#     the wire — never a 500 and never a wrong answer served as 200. The beat's
#     own comment enumerates which layer answers which argument; it does not
#     claim more than it probes. It ALSO carries a control on its own oracle: a
#     neighborhood value that spells three of the leak strings must be BLOCKED,
#     never a BREACH on its own echo.
#   WholeValuedFloatBody — the ONE beat here that asserts an ACCEPTANCE: the
#     two halves of the wire disagree about `2.0` ON PURPOSE (spec §8.1 item
#     8), so `?party_size=2.0` on the availability QUERY is a typed 400 while
#     `{"party_size": 2.0}` on the book_table ACTION books a party of TWO —
#     and a one-sided battery is how the accepted half drifts
#   DeviceGrantRoleSelfSelection (from `kiosk-redteam`, shared by every demo) —
#     the account-binding claim ceremony's UNAUTHENTICATED opening request
#     refuses `role`/`scope` at a DECLARED value as well as an invented one,
#     while the role-less request still opens the ceremony
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
# Exits 0 when every scenario is BLOCKED (0 BREACH); exits 1 on any BREACH, and
# on a battery that produced no proofs at all; exits 2 when a beat could not be
# exercised and was not expected to skip.
# A BREACH = a real hole in atablefor — fix the app, not the scenario.

require "date"
require "json"
require "securerandom"
require "uri"

# The shared harness: the wire this battery attacks over, the ledger it files
# its verdicts into, the leak oracle its hostile-input beats ask, and the one
# library beat further down. Everything in this file that is not about
# atablefor is the gem's.
require "kiosk/redteam"

require_relative "bound_assistant"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER", SERVER)

# ── The two principals, EARNED rather than asserted ──────────────────────────
#
# Both principals run the full shipped ceremony
# (script/bound_assistant.rb): Equihash-tolled `/auth/register` → the diner's real
# Devise sign-in → `/auth/link` → `/auth/claim`. That costs a couple of
# sub-second proofs and buys the thing this suite is FOR — every cross-owner
# refusal below is a refusal between two principals the shipped code
# issued, at the role IT chose, bound to two accounts a human actually holds.
#
# TWO SEEDED HUMANS, not two assistants for one human, and that is the whole
# point of the boundary: `my_bookings` and `cancel_booking` scope by ACCOUNT,
# so two assistants linked to one diner would legitimately see each other's
# bookings and CrossTenantRead would be asserting the opposite of the truth.
# Diego and Bea are separate account holders (db/seeds.rb); the rake task
# passes their credentials in the environment.
#
# `agent_id` is MINTED by `/auth/register` and is a uuid because the schema
# says so: `kiosk.agents.id`, every `kiosk.*_mandates.agent_id` and
# `kiosk.current_agent_id()` are typed `uuid`, so an identity carrying anything
# else is one the shipped tables cannot store. A driver cannot choose it at
# all, which is the strongest form of that guarantee.
DIEGO = bind_assistant(server: SERVER, issuer: ISSUER,
                       email:    ENV.fetch("HOLDER_A_EMAIL"),
                       password: ENV.fetch("HOLDER_A_PASSWORD"))
BEA   = bind_assistant(server: SERVER, issuer: ISSUER,
                       email:    ENV.fetch("HOLDER_B_EMAIL"),
                       password: ENV.fetch("HOLDER_B_PASSWORD"))

DIEGO_UUID = DIEGO.user_id
BEA_UUID   = BEA.user_id
TOKEN_A    = DIEGO.token
TOKEN_B    = BEA.token

# THE 0.4 WIRE. An action is `POST <endpoint>/<action-name>` carrying its
# arguments as the JSON body; a query is `GET <endpoint>/<query-name>` carrying
# them in the query string. A success body IS the result; an error is an RFC
# 9457 problem document whose branch point is the TOP-LEVEL `code`.
WIRE = Kiosk::Redteam::Wire.new(base_url: SERVER)

# One ledger for every beat below — the hand-written ones about atablefor's own
# verbs and the library one about the ceremony every origin serves — printed in
# one vocabulary and answered by one exit status.
BATTERY = Kiosk::Redteam::Battery.new

# Find an open (restaurant, table, seating) row for a 2-top across the
# aggregator, excluding any [restaurant_table_id, seating_at] pairs.
def open_slot(exclude = [])
  rc, avail = WIRE.get_json("/kiosk/availability", { party_size: 2 }, WIRE.bearer(TOKEN_A))
  abort "availability failed (#{rc}): #{JSON.generate(avail)} — run rake demo:setup" unless rc == 200
  rows = Array(avail).reject { |r| exclude.include?([r["restaurant_table_id"], r["seating_at"]]) }
  slot = rows.first
  abort "no open table for a 2-top (excluding #{exclude.inspect})" unless slot
  slot
end

# Book an availability row as `token`, optionally injecting extra args.
def book_slot(token, slot, extra = {})
  WIRE.post_json("/kiosk/book_table",
                 { restaurant_id: slot.fetch("restaurant_id"),
                   restaurant_table_id: slot.fetch("restaurant_table_id"),
                   date: slot.fetch("seating_date"), time: slot.fetch("seating_time"),
                   party_size: 2 }.merge(extra),
                 WIRE.bearer(token))
end

# ── Fixture: Diego books a table (target for cross-owner probes) ──────────────
slot_a = open_slot
rc, diego_book = book_slot(TOKEN_A, slot_a)
abort "A book_table failed (#{rc}): #{JSON.generate(diego_book)} — run rake demo:setup" unless rc == 200
diego_booking_id = diego_book["booking_id"]
abort "no booking_id from A's booking: #{JSON.generate(diego_book)}" unless diego_booking_id

# ── CrossTenantRead — Bea must not see Diego's booking in my_bookings ─────────
rc, b_mine = WIRE.get_json("/kiosk/my_bookings", {}, WIRE.bearer(TOKEN_B))
b_ids = Array(b_mine).map { |r| r["booking_id"] }
BATTERY.record("CrossTenantRead",
               rc == 200 && !b_ids.include?(diego_booking_id),
               "Bea's my_bookings #{b_ids.inspect} excludes Diego's #{diego_booking_id}")

# ── ForgedUserId — Bea books with a forged user_id (Diego's) ─────────────────
#
# `input_schema` is validated on every call and `book_table` declares
# `additionalProperties: false` — the principal is not one of its inputs — so
# the forgery is REFUSED before the handler runs, with a typed 400 naming the
# offending parameter. Both halves are asserted: the wire refuses it, AND
# nothing belonging to Bea appears under Diego. The refusal writes nothing, so
# the seating it named is still free for the legitimate booking below.
slot_b = open_slot([[slot_a["restaurant_table_id"], slot_a["seating_at"]]])
rc, forged = book_slot(TOKEN_B, slot_b, user_id: DIEGO_UUID)
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("user_id")

# And the principal really does come from the token, not from anything the
# caller sent: Bea's LEGITIMATE booking lands under Bea and never under Diego.
rc_b, beas = book_slot(TOKEN_B, slot_b)
bea_booking_id = beas["booking_id"]
rc_a, a_mine = WIRE.get_json("/kiosk/my_bookings", {}, WIRE.bearer(TOKEN_A))
a_ids = Array(a_mine).map { |r| r["booking_id"] }
BATTERY.record("ForgedUserId",
               refused && rc_b == 200 && rc_a == 200 && !a_ids.include?(bea_booking_id),
               "forged user_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming user_id); " \
               "Diego's bookings #{a_ids.inspect} exclude Bea's #{bea_booking_id.inspect}")

# ── CrossOwnerCancel — Bea cancels Diego's booking → 403 ─────────────────────
rc, _ = WIRE.post_json("/kiosk/cancel_booking",
                       { booking_id: diego_booking_id },
                       WIRE.bearer(TOKEN_B))
BATTERY.record("CrossOwnerCancel", rc == 403, "Bea cancel Diego's booking → #{rc} (want 403)")

# ── MalformedUuidArg — a junk booking_id must be a typed 400, never a 500 ────
# cancel_booking casts its booking_id `::uuid`, and without the Kiosk::UuidCheck guard
# a malformed value makes Postgres raise InvalidTextRepresentation — not a
# Kiosk error, so it escapes as a raw 500 carrying the PG message. Three
# properties are asserted, not one: the status is
# 400 (a client mistake reported as such), the problem document's TOP-LEVEL
# `code` is the typed `bad_request` an assistant can branch on, and NO SQL
# internals reach the wire.
#
# The refusal usually comes from the schema layer: `cancel_booking` declares
# `booking_id` as `{type: "string", format: "uuid"}` and `input_schema` is
# validated on every call, so most of these are answered before
# {WireArguments.booking_id} runs. The three properties above are asserted as
# PROPERTIES rather than as a sentence for exactly that reason, and the
# handler guard remains as defence in depth.
MALFORMED_IDS = ["not-a-uuid", "1; DROP TABLE bookings", "", "  "].freeze
SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

# THE SCAN IS TOLD WHAT THIS PROBE SENT. atablefor answers a bad
# argument by NAMING the value it got, so the bytes searched for SQL_INTERNALS
# are partly the probe's own; without the `supplied:` declaration a probe whose
# junk id spelled `PG::` would be reported as a BREACH on its own echo, under a
# runner whose own prose says a BREACH means "fix the app, not the scenario".
# {Kiosk::Redteam::LeakScan} discounts a needle only where those exact bytes lie
# inside one contiguous run the probe supplied — see the gem for why that is not
# a `gsub`.
def uuid_guard_verdict(path, body_for)
  MALFORMED_IDS.map do |junk|
    args     = body_for.call(junk)
    rc, body = WIRE.post_json(path, args, WIRE.bearer(TOKEN_A))
    scan = Kiosk::Redteam::LeakScan.scan(body, SQL_INTERNALS, supplied: args)
    ok = rc == 400 && body["code"] == "bad_request" && !scan.leak?
    [ok, "#{junk.inspect}→#{rc}/#{body['code'].inspect}" \
         "#{scan.leak ? " LEAK #{scan.leak}" : ''}#{scan.note}"]
  end
end

cancel_probes = uuid_guard_verdict("/kiosk/cancel_booking", ->(junk) { { booking_id: junk } })
BATTERY.record("MalformedUuidArg", cancel_probes.all? { |ok, _| ok },
               "cancel_booking with a malformed booking_id → #{cancel_probes.map(&:last).join(', ')} " \
               "(want 400/\"bad_request\" and no SQL internals)")

# ── RegisterWithoutPoP — register with no proof-of-possession → not 201 ──────
require "openssl"
throwaway_pem = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
rc, _ = WIRE.post_json("/kiosk/auth/register", { public_key: throwaway_pem })
BATTERY.record("RegisterWithoutPoP", rc != 201, "register with no signed PoP → #{rc} (want != 201)")

# ── MissingAuth — no Authorization header → 401 ──────────────────────────────
rc, _ = WIRE.get_json("/kiosk/availability", { party_size: 2 })
BATTERY.record("MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

# ── GarbageToken — unparseable bearer → 401 ──────────────────────────────────
rc, _ = WIRE.get_json("/kiosk/availability", { party_size: 2 }, WIRE.bearer("not-a-real-token"))
BATTERY.record("GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# ── SelfAssertedTokenForgery ─────────────────────────────────────────────────
# Agent auth is the engine's own kiosk-pop verifier, which has no cleartext
# branch to fall back to in any environment, so an `agent:u-…:a-…:r-…` string
# is not a credential in any environment either. The assertion is therefore
# unconditional and lands over the LIVE WIRE, in the same environment as every
# other beat here: a self-asserted bearer resolves to NO identity. There is no
# `Rails.env` anywhere in it.
#
# The first probe is the STRONGEST form of the attack rather than the easiest —
# it names a real account and a real agent (the ones the ceremony above just
# minted for Diego) and escalates the role to `owner`, so nothing in the string
# is invented except the claim that it is a credential. The second is the
# wholly-made-up one. The earned token is the positive control on the same
# verb, so a 401 above is the forgery being refused and not the surface being
# down.
self_asserted = [
  ["real account + real agent, role escalated to owner",
   "agent:u-#{DIEGO_UUID}:a-#{DIEGO.agent_id}:r-owner"],
  ["wholly invented ids",
   "agent:u-#{SecureRandom.uuid}:a-#{SecureRandom.uuid}:r-owner"],
].map do |label, token|
  code, = WIRE.get_json("/kiosk/availability", { party_size: 2 }, WIRE.bearer(token))
  [code == 401, "#{label} → #{code}"]
end
rc_auth_ctl, = WIRE.get_json("/kiosk/availability", { party_size: 2 }, WIRE.bearer(TOKEN_A))
BATTERY.record("SelfAssertedTokenForgery",
               self_asserted.all? { |ok, _| ok } && rc_auth_ctl == 200,
               "self-asserted `agent:u-…:r-owner` bearer: #{self_asserted.map(&:last).join(', ')} " \
               "(want 401 each, unconditionally — this IS a development server); " \
               "CONTROL the earned token → #{rc_auth_ctl} (want 200)")

# ── UnknownQuery — unregistered query name → 404 ─────────────────────────────
rc, _ = WIRE.get_json("/kiosk/frobnicate", {}, WIRE.bearer(TOKEN_A))
BATTERY.record("UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = WIRE.post_json("/kiosk/nope", {}, WIRE.bearer(TOKEN_A))
BATTERY.record("UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── UnregisteredVerbIsOrdinaryRefusal — a path naming no verb is refused ─────
# `POST /kiosk/query` and `POST /kiosk/run` name no verb this origin registers,
# so no line in config/routes/kiosk.rb draws them and nothing under the mount
# matches: the answer is the ordinary 404 any undrawn path gets — no privileged
# endpoint behind a generic-sounding word, and no second conformance surface to
# attack. Those two names are what a caller hunting for a multiplexed endpoint
# tries first, which is why the beat dials them rather than a nonsense word.
#
# BOTH CALLERS ARE PROBED, and the point is that they answer ALIKE. A routing
# miss is decided before any credential is read, so a bearer buys nothing here:
# the anonymous caller and the authenticated one get the same 404, and neither
# gets a Kiosk problem document to read anything out of.
unregistered = %w[query run].flat_map do |name|
  authed = WIRE.request(:post, "/kiosk/#{name}", body: { name: "availability", party_size: 2 },
                        headers: WIRE.bearer(TOKEN_A))
  anon   = WIRE.request(:post, "/kiosk/#{name}", body: { name: "availability", party_size: 2 })
  [[authed.status == 404 && authed.body["code"].nil?, "#{name}→#{authed.status}"],
   [anon.status   == 404 && anon.body["code"].nil?,   "#{name}(anon)→#{anon.status}"]]
end
BATTERY.record("UnregisteredVerbIsOrdinaryRefusal",
               unregistered.all? { |ok, _| ok },
               "unregistered verb names #{unregistered.map(&:last).join(', ')} " \
               "(want a plain 404 with no problem-document code, bearer or not)")

# ── MethodMismatch — a GET at an action's path does not serve the write ──────
# This origin draws `POST /kiosk/book_table` and nothing else at that path, so a
# GET matches no route and is the same ordinary 404 an undrawn path gets. What
# the beat is FOR is the security half: the wrong method must never reach the
# action. The catalogue is where a caller learns which method a verb takes.
res404 = WIRE.request(:get, "/kiosk/book_table", headers: WIRE.bearer(TOKEN_A))
BATTERY.record("MethodMismatch",
               res404.status == 404 && res404["allow"].nil? && res404.body["code"].nil?,
               "GET an action → #{res404.status} Allow=#{res404['allow'].inspect} " \
               "(want a plain 404, no Allow, no problem-document code)")

# ── InvalidFilterIsNotAnEmptyList ────────────────────────────────────────────
# AN INVALID FILTER VALUE IS A TYPED 400 WITH A DESCRIPTION, never an empty
# list. From the assistant's side `200 []` for a mistyped filter is
# indistinguishable from a sold-out night, so a typo and a full house would
# read the same.
#
# Every probe sends a value that is WELL-FORMED and wrong: `time: "18:00"` is
# a valid clock time that is not one of the seatings, and any date past the
# rolling horizon is a valid `format: "date"`. `time` is an `enum` on the
# descriptor and `date` keeps an explicit handler guard, because a horizon
# that rolls forward daily cannot be named in a schema written at declaration
# time.
#
# WHICH LAYER ANSWERS EACH ONE, AND THE ASSERTION DELIBERATELY DOES NOT CARE.
# `input_schema` is validated on every per-verb call, so `time=18:00` is
# refused by the DECLARED `enum` before the handler runs — ``value at `/time`
# is not one of: ["19:00", "20:00", "21:00"]``. The out-of-horizon `date`
# reaches the handler guard instead, because no `enum` written at declaration
# time can name a horizon that rolls forward daily. Both are checked for the
# same thing: a TYPED 400 whose detail NAMES the valid values, which is what an
# assistant actually recovers from — not a sentence a particular layer happened
# to phrase.
#
# The assertion is a TYPED 400 that NAMES the valid values — not merely
# "not 200". An unnamed 400 would refuse correctly and still leave the
# assistant fetching the schema to find out what it should have sent. The
# empty path is still held to not being a crash: a 500 fails this beat just as
# it fails every other. The non-empty positive control is what keeps the beat
# from passing against a handler that refuses everything.
#
# THE THIRD FILTER, `neighborhood`, is the one no schema can hold: its served
# set is DB-DERIVED, so it can never be an `enum` — the refusal comes from
# {WireArguments.neighborhood} and names the neighbourhoods that exist, exactly
# as the `date` guard names the horizon.
#
# THE HORIZON HAS TWO ENDS AND BOTH ARE PROBED. A date BEHIND it is refused by
# the very same {WireArguments.seating_date} guard, because `Seatings.upcoming`
# starts at today in Europe/Lisbon and drops today's already-started seatings.
# It lives here rather than in a beat of its own because it is literally the
# same guard answering the same question from the other side.
#
# «PAST» ON THIS DEMO IS AN INSTANT, NOT A DAY: atablefor sells three named
# evening SEATINGS rather than whole days, so tonight's 19:00 stops being
# offered at 19:00 while tonight's 21:00 is still bookable. The floor is
# therefore "has this seating started?", read in the restaurant's
# own clock (Europe/Lisbon), and TODAY IS PARTLY BOOKABLE — which is why the
# probe below uses a date 30 days back rather than today: a probe on today
# would be a test of the RUNNER's timezone, not of the operator's.
FAR_FUTURE = (Date.today + 3650).iso8601
PAST_DATE  = (Date.today - 30).iso8601
invalid_filter_probes = [
  ["time=18:00 (valid pattern, not a seating)",
   { party_size: 2, time: "18:00" }, %w[19:00 20:00 21:00]],
  ["date=#{FAR_FUTURE} (valid date, past the horizon)",
   { party_size: 2, date: FAR_FUTURE }, ["upcoming seatings"]],
  ["date=#{PAST_DATE} (valid date, BEHIND the horizon)",
   { party_size: 2, date: PAST_DATE }, ["upcoming seatings"]],
  ["neighborhood=Atlantis (well-formed, unserved)",
   { party_size: 2, neighborhood: "Atlantis" }, ["Alfama"]],
  ["both filters, no overlap",
   { party_size: 2, time: "18:00", date: FAR_FUTURE }, %w[19:00 20:00 21:00]],
].map do |label, args, named|
  rc, resp = WIRE.get_json("/kiosk/availability", args, WIRE.bearer(TOKEN_A))
  code   = resp.is_a?(Hash) ? resp["code"] : nil
  detail = resp.is_a?(Hash) ? resp["detail"].to_s : ""
  names  = named.all? { |value| detail.include?(value) }
  ok = rc == 400 && code == "bad_request" && names
  [ok, "#{label} → #{rc}/#{code.inspect}#{ok ? " naming #{named.join(", ")}" : "/#{JSON.generate(resp)[0, 160]}"}"]
end
rc_ctl, ctl = WIRE.get_json("/kiosk/availability", { party_size: 2 }, WIRE.bearer(TOKEN_A))
control_ok = rc_ctl == 200 && Array(ctl).any?
BATTERY.record("InvalidFilterIsNotAnEmptyList",
               invalid_filter_probes.all? { |ok, _| ok } && control_ok,
               "#{invalid_filter_probes.map(&:last).join(', ')}; CONTROL unfiltered → " \
               "#{rc_ctl}/#{(rc_ctl == 200 ? Array(ctl).size : 0)} rows " \
               "(want 400 bad_request naming the valid values for each filter, and a non-empty control)")

# ── BookOutsideOfferedHorizon ────────────────────────────────────────────────
#
# THE WRITE SIDE OF THE BEAT ABOVE. `availability` refuses an out-of-horizon
# `date` filter, and `book_table` has to refuse one too. A date guard that
# asks only "has this seating already started?" answers NO for a date weeks
# out, and the booking is then written for a (table, seating) `availability`
# has never listed and will not list until the rolling window reaches it.
#
# TWO LAYERS ANSWER, AND WHICH ONE IS THE POINT OF THE SECOND PROBE. The
# out-of-horizon date reaches the handler guard, because no `enum` written at
# declaration time can name a horizon that rolls forward daily, and the refusal
# NAMES the bookable dates. The basic-ISO spelling — `20260821` rather than
# `2026-08-21` — never gets that far: `book_table` declares `format: "date"`
# and 0.4 validates `input_schema` on every call, so the wire refuses the
# spelling the descriptor does not advertise before any Ruby runs. It is worth
# probing anyway, because it is what says the wire layer really is there: the
# handler behind it refuses the same spelling ({WireArguments.iso_date}), so a
# green probe here has to be attributed to a layer rather than assumed, and the
# two together leave no way in.
#
# Both are asserted as a TYPED 400 naming what was wrong — a 500 or a silent
# success fails either one — and the horizon probe additionally has to name the
# dates that WOULD work, which is what an assistant recovers from.
horizon_slot = open_slot
horizon_probes = [
  ["date=#{FAR_FUTURE} (valid date, beyond the rolling horizon)", FAR_FUTURE, "upcoming seatings"],
  # The near end of the same horizon. The sentence differs from the far
  # end's on purpose and is not this beat's to normalise: a date behind the
  # horizon trips `Seatings.past?` FIRST, so the refusal is «seating … has
  # already started — call availability again for the still-bookable seatings»,
  # which names where a bookable value comes from rather than listing them. Both
  # are typed 400s an assistant recovers from, which is what is asserted.
  ["date=#{PAST_DATE} (valid date, BEHIND the rolling horizon)",
   PAST_DATE, "already started"],
  ["date=#{Date.today.strftime('%Y%m%d')} (basic ISO-8601 — not the advertised YYYY-MM-DD)",
   Date.today.strftime("%Y%m%d"), "date"],
].map do |label, bad_date, named|
  rc, resp = book_slot(TOKEN_A, horizon_slot, date: bad_date)
  code   = resp.is_a?(Hash) ? resp["code"] : nil
  detail = resp.is_a?(Hash) ? resp["detail"].to_s : ""
  ok = rc == 400 && code == "bad_request" && detail.include?(named)
  [ok, "#{label} → #{rc}/#{code.inspect}#{ok ? " naming #{named}" : "/#{JSON.generate(resp)[0, 160]}"}"]
end
# Positive control: the SAME row, booked with the date availability published,
# still succeeds — so the beat cannot pass against a book_table that refuses
# every date.
rc_horizon_ctl, horizon_ctl = book_slot(TOKEN_A, horizon_slot)
horizon_control_ok = rc_horizon_ctl == 200 && !horizon_ctl["booking_id"].to_s.empty?
BATTERY.record("BookOutsideOfferedHorizon",
               horizon_probes.all? { |ok, _| ok } && horizon_control_ok,
               "#{horizon_probes.map(&:last).join(', ')}; CONTROL same row at its published date → " \
               "#{rc_horizon_ctl}/#{horizon_ctl['booking_id'].inspect} " \
               "(want 400 bad_request naming the horizon for each, and a confirmed control)")

# ── HostileArgShapes ─────────────────────────────────────────────────────────
#
# Every `party_size` in the beats above is the legal `2`; this is the beat that
# varies the SHAPE of an argument rather than its value.
#
# WHAT IS PROBED, NAMED RATHER THAN CLAIMED — a beat whose comment CLAIMS
# coverage is itself the defect. Exactly these:
#
#   book_table      party_size, restaurant_id, restaurant_table_id  (INT_SHAPES)
#                   date, time                                      (NONSTRING)
#   availability    party_size  (the junk scalars a query string can express,
#                                plus the two BRACKET spellings)
#   cancel_booking  booking_id                                      (NONSTRING)
#
# An argument NOT on that list is not covered here — extend the list, never
# widen the sentence. `availability`'s `neighborhood`/`time`/`date` and
# `cancel_booking`'s malformed-uuid STRINGS are covered by
# InvalidFilterIsNotAnEmptyList and MalformedUuidArg above; those two beats send
# well-formed strings with wrong VALUES, which is the other half of the story
# and not this one.
#
# WHICH LAYER ANSWERS WHICH, MEASURED at head rather than assumed, because it
# differs per argument and the difference is the whole point of the beat:
#
#   * `party_size` — BOTH LAYERS REFUSE EVERY SHAPE BELOW. The handler guard
#     {WireArguments.party_size} goes through {WireArguments.whole_number},
#     which is json_schemer's own `integer` (so `2.0` is still a party of two
#     — measured against this demo's bundle). A bare `raw.to_i` there is the
#     hole: `true`, `false`, `[]`, `{}`, `[1]` and `{"a" => 1}` have no
#     `to_i`, so each is a `NoMethodError` → `500 action_failed`, and
#     `1.5.to_i` is 1, so a fractional party is SEATED as a party of one.
#     WATCHED FAIL, run and restored: drop `party_size`'s declared `type` from
#     `book_table`'s `input_schema` and these stay 400 off the second layer;
#     with a bare `.to_i` restored underneath, the same mutation makes them
#     a 500 for the six raising shapes and a CONFIRMED BOOKING for `1.5`.
#     THE SAME MUTATION ON `availability` SAYS SOMETHING ELSE, and it is
#     recorded rather than smoothed over: drop the type there and the QUERY
#     decoder stops coercing, so the guard is handed the raw string `"2"` and
#     refuses a legal party of two — this battery aborts on its first
#     availability call. The second layer is the schema's `integer` exactly, so
#     on the query half it is the DECODER that turns the wire's string into one;
#     independent of the descriptor for `book_table`, downstream of it here.
#   * `restaurant_id` and `restaurant_table_id` — BOTH LAYERS REFUSE EVERY
#     SHAPE BELOW. The declared `{type: "integer", minimum: 1}` answers first;
#     behind it {BookTableOperation}'s own `identifier` routes each through
#     {WireArguments.whole_number} — json_schemer's `integer`, the same one
#     `party_size` uses, so `2.0` still resolves to 2 — and only then asks
#     `>= 1`.
#     NEITHER ARGUMENT HAS A QUERY HALF, which is the one way this pair differs
#     from `party_size`: `book_table` is the only verb on this origin that takes
#     either (`availability` and `my_bookings` only ever RETURN them), so no
#     {Kiosk::Server::ArgumentDecoder} sits anywhere in their path and this
#     second layer is independent of the descriptor on both counts.
#     WATCHED FAIL, run and restored: drop BOTH declared `type`s from
#     `book_table`'s `input_schema` and all 62 probes stay 400 off the second
#     layer; with a bare `.to_i` restored underneath, the same mutation breaks
#     TWELVE of them — the six raising shapes × the two arguments, each a
#     `500 action_failed` LEAKing `NoMethodError`.
#     `1.5` DOES NOT BREACH UNDER THAT MUTATION AND THE REASON IS RECORDED
#     RATHER THAN SMOOTHED OVER, because it is the more dangerous half: `.to_i`
#     turns it into 1, and whether resolving to row 1 is a WRONG BOOKING or a
#     400 depends on the SEEDED DATA, not on the guard. This beat's slot is not
#     restaurant 1 table 1, so the mismatch falls out as "no such table 1 at
#     restaurant 2" — a typed refusal naming a table nobody asked for, which is
#     why the probes above stay green on that value. Measured on the
#     descriptor-less path with a bare `.to_i` underneath:
#     `BookTableOperation.call(restaurant_id: 1.5, restaurant_table_id: 1, …)`
#     returned a CONFIRMED BOOKING at restaurant 1 table 1. A probe set cannot
#     pin that half, so the guard has to.
#   * `date` and `time` — the declared `format: "date"` and `enum` answer the
#     non-string shapes; the handler guards behind them ({WireArguments
#     .seating_date}, {WireArguments.seating_time}) read through `to_s`, so they
#     cannot raise but they cannot refuse a shape either.
#   * `booking_id` — the declared `format: "uuid"` answers first;
#     {WireArguments.booking_id}'s `blank?`/`Kiosk::UuidCheck` behind it reads every
#     shape without raising, so this half is two layers for the STRINGS
#     MalformedUuidArg sends and the schema's alone for the container shapes here.
#
# AND THE ERROR BODY MUST NOT CARRY THE RUNTIME'S OWN VOCABULARY: these probes
# are the ones most likely to reach a cast or a `NoMethodError`, so every
# response is checked for the SQL-cast leak strings plus the two
# `NoMethodError` spellings a shape crash would print.
SHAPE_LEAKS = ["NoMethodError", "undefined method", "TypeError",
               "no implicit conversion", "::uuid", "::integer", "::date", "PG::",
               "22P02", "invalid input syntax", "ActiveRecord::", "ActiveModel::"].freeze

# The five families, per argument type. INT_SHAPES is hoteling's list verbatim,
# so the three ORM demos probe the same set; NONSTRING drops the values that ARE
# strings, because a string is what those arguments are declared to be and a
# wrong-VALUE string is the beat above's business.
INT_SHAPES = [true, false, [], {}, [1], { "a" => 1 }, "abc", nil, 1.5, "0x10"].freeze
NONSTRING  = [true, false, [], {}, [1], { "a" => 1 }, nil, 20260826].freeze
# What a QUERY string can express: everything arrives as a string, so the only
# hostile shapes left are junk scalars — plus the two bracket spellings, which
# Rack folds into an Array and a Hash before the decoder ever sees them.
#
# `"2.0"` IS ON THIS LIST AND IS NOT ON book_table's, and the asymmetry is the
# wire's rather than this beat's: a JSON `2.0` is a valid `integer` to
# json_schemer and books a party of two through the action, while the query
# decoder's `Integer(v, 10)` refuses the STRING `"2.0"` outright.
#
# THE DIFFERENCE IS PUBLISHED behaviour — spec Section 8.1 item 8 and the
# narrative specification say a query parameter declared `integer` takes an
# integer LITERAL and nothing else, while a body field declared `integer` takes
# any JSON number whose value is whole, and that the difference is intentional.
# The strict query half is the right one, and a field that may legitimately be
# fractional must DECLARE itself `number` rather than `integer`. Both halves
# are pinned so neither can drift into the other — the
# query half twice (this probe, and kiosk-server's
# `refuses a WHOLE-VALUED float where an integer is declared` unit example) and
# the body half by the `WholeValuedFloatBody` beat below, which asserts on a
# booted origin that the action ACCEPTS what this line asserts the query refuses.
QUERY_JUNK = ["abc", "true", "1.5", "0x10", "", "2.0"].freeze

# `supplied:` is what this probe put on the wire, and it is what stops the
# assertion being decided by the attacker — see {uuid_guard_verdict}'s note
# above. It defaults to nil, and that default fails SAFE: a beat that forgets
# to declare risks a FALSE BREACH, never a missed leak.
def shape_verdict(label, rc, body, supplied: nil)
  scan = Kiosk::Redteam::LeakScan.scan(body, SHAPE_LEAKS, supplied: supplied)
  code = body.is_a?(Hash) ? body["code"] : nil
  ok   = rc == 400 && code == "bad_request" && !scan.leak?
  [ok, "#{label}→#{rc}/#{code.inspect}#{scan.leak ? " LEAK #{scan.leak}" : ''}#{scan.note}"]
end

shape_slot   = open_slot
shape_probes = []

INT_SHAPES.each do |v|
  %i[party_size restaurant_id restaurant_table_id].each do |arg|
    rc, body = book_slot(TOKEN_A, shape_slot, arg => v)
    shape_probes << shape_verdict("book_table #{arg}=#{v.inspect}", rc, body, supplied: { arg => v })
  end
end
NONSTRING.each do |v|
  %i[date time].each do |arg|
    rc, body = book_slot(TOKEN_A, shape_slot, arg => v)
    shape_probes << shape_verdict("book_table #{arg}=#{v.inspect}", rc, body, supplied: { arg => v })
  end
  rc, body = WIRE.post_json("/kiosk/cancel_booking", { booking_id: v }, WIRE.bearer(TOKEN_A))
  shape_probes << shape_verdict("cancel_booking booking_id=#{v.inspect}", rc, body, supplied: { booking_id: v })
end
QUERY_JUNK.each do |v|
  rc, body = WIRE.get_json("/kiosk/availability", { party_size: v }, WIRE.bearer(TOKEN_A))
  shape_probes << shape_verdict("availability party_size=#{v.inspect}", rc, body, supplied: { party_size: v })
end
# The bracket spellings, which URI.encode_www_form cannot produce: they are
# written into the path so Rack's own parser folds them into an Array and a Hash.
["party_size%5B%5D=2", "party_size%5Bx%5D=2"].each do |bracket|
  rc, body = WIRE.get_json("/kiosk/availability?#{bracket}", {}, WIRE.bearer(TOKEN_A))
  shape_probes << shape_verdict("availability #{bracket}", rc, body, supplied: bracket)
end

# ── MAGNITUDE, not type — the axis INT_SHAPES does not have ──────────────────
#
# Every value in INT_SHAPES varies an argument's TYPE, and none of them is an
# integer too LARGE for the column behind it.
#
# MEASURED on a booted origin without the declared bound: `party_size:
# 2_147_483_648` passes `{type: "integer", minimum: 1}` (no ceiling), passes
# {WireArguments.party_size} (a whole number >= 1), and reaches
# `RestaurantTable.where(capacity.gteq(party_size))` — `capacity` is a
# PostgreSQL `integer` — where ActiveRecord raises `ActiveModel::RangeError`
# CASTING the comparison, on BOTH surfaces that take a party: `book_table`
# (`book_table_operation.rb`) and `availability`
# (`dining_room_controller.rb`), and both answer HTTP 500. `party_size`
# declares the column's own width as its `maximum`, and the shared guard
# mirrors it, so both are a typed 400 from the schema layer.
#
# THE TWO IDENTIFIERS ARE DELIBERATELY NOT PROBED HERE, AND THAT IS MEASURED
# RATHER THAN ASSUMED: `restaurant_id` and `restaurant_table_id` reach
# ActiveRecord as EQUALITY predicates (`where(id: …, restaurant_id: …)`), and an
# out-of-range value there answers ZERO ROWS instead of raising — so a huge id
# is already the ordinary "no such table" 400 this suite's other beats cover.
# Only the `gteq` COMPARISON casts, and `party_size` is the only wire argument
# that reaches one.
BEYOND_INT4 = 2_147_483_648 # one past PostgreSQL `integer`
rc, body = book_slot(TOKEN_A, shape_slot, party_size: BEYOND_INT4)
shape_probes << shape_verdict("book_table party_size=#{BEYOND_INT4}", rc, body, supplied: { party_size: BEYOND_INT4 })
rc, body = WIRE.get_json("/kiosk/availability", { party_size: BEYOND_INT4 }, WIRE.bearer(TOKEN_A))
shape_probes << shape_verdict("availability party_size=#{BEYOND_INT4}", rc, body, supplied: { party_size: BEYOND_INT4 })

# ── NEGATIVE CONTROL FOR THE ORACLE ITSELF ──────────────────────────────────
#
# Every probe above asserts something about atablefor. This one asserts
# something about the ASSERTION: that a needle reaching the wire ONLY because
# the probe put it there is not reported as a breach. Without it the fix above
# is untested, and a later "simplification" back to
# `SHAPE_LEAKS.find { |n| raw.include?(n) }` would pass every other probe in
# this file.
#
# `neighborhood` is the right argument and the choice is measured, not
# convenient: it is declared a bare `{type: "string"}` because the served set is
# DB-derived, so json_schemer cannot refuse it and the value reaches
# {WireArguments.neighborhood}, whose refusal NAMES it back. The two arguments
# whose refusals also echo — `party_size` and the two identifiers — are answered
# by the descriptor first, and json_schemer's message names the POINTER rather
# than the value, so a needle sent there never reaches the body at all and the
# control would be vacuous.
#
# WATCHED FAIL, run and restored: drop `supplied:` from this one call and this
# probe alone goes red, reporting `LEAK PG::` — the false BREACH, on a demo with
# no hole in it, under the header line that tells the reader to fix the app.
ECHO_CONTROL = "PG::22P02 invalid input syntax"
rc_echo, body_echo = WIRE.get_json("/kiosk/availability",
                                   { party_size: 2, neighborhood: ECHO_CONTROL }, WIRE.bearer(TOKEN_A))
ok_echo, detail_echo = shape_verdict(
  "availability neighborhood=<a value spelling three SHAPE_LEAKS> (oracle control)",
  rc_echo, body_echo, supplied: { party_size: 2, neighborhood: ECHO_CONTROL }
)
# VACUITY GUARD, the same one every other control in this file carries: the
# probe proves nothing unless the refusal really did echo the value back. If
# this demo ever stops naming the value it got, this says so rather than
# passing quietly on a question that was never asked.
unless JSON.generate(body_echo).include?(ECHO_CONTROL)
  ok_echo = false
  detail_echo += " [CONTROL VACUOUS: the refusal did not echo the value, so the " \
                 "oracle was never asked to tell an echo from a leak]"
end
shape_probes << [ok_echo, detail_echo]

# Positive controls, one per verb touched, so the beat cannot pass against an
# origin that refuses everything: the SAME availability row books at its
# published values, and the booking it makes cancels.
rc_shape_book, shape_book = book_slot(TOKEN_A, shape_slot)
rc_shape_cancel, = WIRE.post_json("/kiosk/cancel_booking",
                                  { booking_id: shape_book["booking_id"] }, WIRE.bearer(TOKEN_A))
rc_shape_avail, shape_avail = WIRE.get_json("/kiosk/availability", { party_size: 2 }, WIRE.bearer(TOKEN_A))
shape_control_ok = rc_shape_book == 200 && !shape_book["booking_id"].to_s.empty? &&
                   rc_shape_cancel == 200 && rc_shape_avail == 200 && Array(shape_avail).any?
BATTERY.record("HostileArgShapes",
               shape_probes.all? { |ok, _| ok } && shape_control_ok,
               "#{shape_probes.size} probes: #{shape_probes.reject { |ok, _| ok }.map(&:last).join(', ')}" \
               "#{shape_probes.all? { |ok, _| ok } ? 'all 400/"bad_request", no leak' : ''}; " \
               "CONTROLS book→#{rc_shape_book} cancel→#{rc_shape_cancel} availability→#{rc_shape_avail}/" \
               "#{rc_shape_avail == 200 ? Array(shape_avail).size : 0} rows " \
               "(want a typed 400 for every probe, never a 5xx and never a 200, and three live controls)")

# ── WholeValuedFloatBody — the OTHER half of the published asymmetry ─────────
#
# THE ONLY BEAT IN THIS FILE WHOSE ASSERTION IS THAT SOMETHING IS ACCEPTED, and
# that is the point: every probe above pins a refusal, so a wire that refused
# EVERYTHING would satisfy them. Spec Section 8.1 item 8 publishes an asymmetry
# with two sides, and a one-sided pin is how the accepted side drifts away
# unnoticed.
#
# THE PAIR, on ONE booted origin, in one beat so the two cannot be read apart:
#   * `?party_size=2.0` on `availability` (a query) is `400 bad_request` naming
#     the parameter — a query string is text, so the declared `integer` is the
#     GRAMMAR the spelling must match and `2.0` is not an integer literal;
#   * `{"party_size": 2.0}` on `book_table` (an action) is `200` and books a
#     party of TWO — a JSON body is already typed, draft 2020-12 decides
#     `integer` by VALUE, and {WireArguments.whole_number} agrees with it on
#     purpose rather than reaching for `is_a?(Integer)`.
# `2.5` is not an integer on either half; INT_SHAPES' `1.5` above is that case,
# so it is not repeated here.
#
# VACUITY GUARDS, because both halves can pass for the wrong reason: the body
# probe checks that the bytes really carried a JSON FLOAT (`"party_size":2.0`,
# not `2`), so a future refactor that quietly sends an Integer cannot leave the
# beat green on a question it stopped asking; and it checks the ANSWER echoed
# `party_size` as the Integer 2, so "accepted" means "read as two" rather than
# merely "not refused".
#
# WATCHED FAIL, run and restored: replace {WireArguments.whole_number}'s Float
# arm with `is_a?(Integer)` — the strict reading of `integer`, i.e. the body half
# behaving like the query half — and this beat alone goes red, `book_table`
# answering 400 «party_size must be a whole number >= 1 — got 2.0».
float_body_json = JSON.generate({ party_size: 2.0 })
rc_fq, body_fq  = WIRE.get_json("/kiosk/availability", { party_size: "2.0" }, WIRE.bearer(TOKEN_A))
float_slot      = open_slot
rc_fb, body_fb  = book_slot(TOKEN_A, float_slot, party_size: 2.0)
query_half_ok   = rc_fq == 400 && body_fq["code"] == "bad_request"
body_half_ok    = rc_fb == 200 && body_fb["party_size"] == 2 &&
                  !body_fb["booking_id"].to_s.empty?
sent_a_float    = float_body_json.include?('"party_size":2.0')
WIRE.post_json("/kiosk/cancel_booking", { booking_id: body_fb["booking_id"] }, WIRE.bearer(TOKEN_A)) if body_half_ok
BATTERY.record("WholeValuedFloatBody",
               query_half_ok && body_half_ok && sent_a_float,
               "query ?party_size=2.0 → #{rc_fq}/#{body_fq['code'].inspect}; " \
               "body {\"party_size\": 2.0} → #{rc_fb}/party_size=#{body_fb['party_size'].inspect} " \
               "booking_id=#{body_fb['booking_id'].inspect}" \
               "#{sent_a_float ? '' : ' [PROBE VACUOUS: the request body did not carry a JSON float]'} " \
               "(want 400 on the query half and a party of TWO on the body half — " \
               "spec Section 8.1 item 8, and it is INTENTIONAL that they differ)")

# ── DeviceGrantRoleSelfSelection — the SHARED framework beat ─────────────────
#
# The one beat in this file that is NOT hand-rolled: it comes from
# `kiosk-redteam`, so every demo runs the SAME assertion about the
# account-binding claim ceremony and a demo cannot be left out of it by
# forgetting to copy a block.
#
# The shared `PrivilegeSelfSelection` scenario probes `/auth/register` only;
# this one covers the UNAUTHENTICATED request that opens the ceremony. An
# origin that declares a SINGLE role is not made safe by that fact: the
# mitigation expires the day it declares a second one, which is why the beat
# runs on every demo rather than in one demo's suite.
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
# beat skipped that this origin was not expected to skip. atablefor expects no
# skips at all — every beat above is about a surface it has.
exit BATTERY.report!
