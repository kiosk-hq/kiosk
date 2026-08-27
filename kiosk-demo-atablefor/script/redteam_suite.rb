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
#                       THIS (development) environment (K-539, restated by
#                       T-104: the cleartext parser is deleted, not gated)
#   UnknownQuery      — an unregistered query name → 404
#   UnknownAction     — an unregistered action name → 404
#   RetiredWire       — the deleted 0.3 `POST /kiosk/{query,run}` answer the
#                       ordinary 404 an authenticated caller gets, and 401
#                       without a bearer; no privileged endpoint left to attack
#   MethodMismatch    — a GET at an action's path is 405 + `Allow: POST`, never
#                       a silent 404
#   InvalidFilterIsNotAnEmptyList — an availability filter naming a seating
#     time, a date or a NEIGHBOURHOOD that does not exist is a typed 400
#     NAMING the valid values, never a 200 with an empty rows array and never
#     a 500 (K-717 and T-090, and K-691 before them)
#   BookOutsideOfferedHorizon — book_table on a well-formed date OUTSIDE the
#     rolling horizon availability offers is a typed 400 NAMING the bookable
#     dates, never a confirmed booking for a seating that was never offered;
#     and the BASIC-form `YYYYMMDD` spelling Date.iso8601 would have accepted
#     is refused by the declared `format: "date"` before the handler (K-767)
#   HostileArgShapes — boolean/array/object/junk values on book_table's
#     party_size, restaurant_id, restaurant_table_id, date and time, on
#     availability's party_size (including the two bracket spellings) and on
#     cancel_booking's booking_id are a typed 400 with no runtime vocabulary on
#     the wire — never a 500 and never a wrong answer served as 200 (K-773,
#     K-1027, K-1028). The beat's own comment enumerates which layer answers
#     which argument; it does not claim more than it probes.
#   DeviceGrantRoleSelfSelection (from `kiosk-redteam`, shared by every demo) —
#     the account-binding claim ceremony's UNAUTHENTICATED opening request
#     refuses `role`/`scope` at a DECLARED value as well as an invented one,
#     while the role-less request still opens the ceremony (K-072, K-1128)
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
require "securerandom"
require "uri"

require_relative "bound_assistant"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER", SERVER)

# ── The two principals, EARNED rather than asserted (T-104) ──────────────────
#
# This battery used to hand itself both principals by writing them down —
# `agent:u-<uuid>:a-<uuid>:r-customer` — which a dev-only parser in the demo
# turned into an authenticated identity at any role it named. That parser is
# gone: agent auth runs through the engine's own kiosk-pop verifier now, so a
# string like that authenticates NOTHING (asserted below, as its own beat).
#
# So both principals run the full shipped ceremony instead
# (script/bound_assistant.rb): Equihash-tolled `/auth/register` → the diner's real
# Devise sign-in → `/auth/link` → `/auth/claim`. That costs a couple of
# sub-second proofs and buys the thing this suite is FOR — every cross-owner
# refusal below is now a refusal between two principals the shipped code
# issued, at the role IT chose, bound to two accounts a human actually holds.
#
# TWO SEEDED HUMANS, not two assistants for one human, and that is the whole
# point of the boundary: `my_bookings` and `cancel_booking` scope by ACCOUNT,
# so two assistants linked to one diner would legitimately see each other's
# bookings and CrossTenantRead would be asserting the opposite of the truth.
# Diego and Bea are separate account holders (db/seeds.rb); the rake task
# passes their credentials in the environment.
#
# `agent_id` is now MINTED by `/auth/register` and is a uuid because the schema
# says so: `kiosk.agents.id`, every `kiosk.*_mandates.agent_id` and
# `kiosk.current_agent_id()` are typed `uuid`, so an identity carrying anything
# else is one the shipped tables cannot store (K-829/K-830). A driver can no
# longer choose it at all, which is the strongest form of that guarantee.
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

# ── Fixture: Diego books a table (target for cross-owner probes) ──────────────
slot_a = open_slot
rc, diego_book = book_slot(TOKEN_A, slot_a)
abort "A book_table failed (#{rc}): #{JSON.generate(diego_book)} — run rake demo:setup" unless rc == 200
diego_booking_id = diego_book["booking_id"]
abort "no booking_id from A's booking: #{JSON.generate(diego_book)}" unless diego_booking_id

# ── CrossTenantRead — Bea must not see Diego's booking in my_bookings ─────────
rc, b_mine = get_json("/kiosk/my_bookings", {}, bearer(TOKEN_B))
b_ids = Array(b_mine).map { |r| r["booking_id"] }
record(results, "CrossTenantRead",
       rc == 200 && !b_ids.include?(diego_booking_id),
       "Bea's my_bookings #{b_ids.inspect} excludes Diego's #{diego_booking_id}")

# ── ForgedUserId — Bea books with a forged user_id (Diego's) ─────────────────
#
# THIS BEAT CHANGED SHAPE AT 0.4 AND GOT STRONGER, so it is worth saying what it
# now proves. Through 0.3 the forged argument was ACCEPTED by the wire and
# IGNORED by the handler, and the proof was indirect: the created booking did
# not surface in Diego's my_bookings. On the 0.4 wire `input_schema` is
# validated on every call and `book_table` declares
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
rc_a, a_mine = get_json("/kiosk/my_bookings", {}, bearer(TOKEN_A))
a_ids = Array(a_mine).map { |r| r["booking_id"] }
record(results, "ForgedUserId",
       refused && rc_b == 200 && rc_a == 200 && !a_ids.include?(bea_booking_id),
       "forged user_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming user_id); " \
       "Diego's bookings #{a_ids.inspect} exclude Bea's #{bea_booking_id.inspect}")

# ── CrossOwnerCancel — Bea cancels Diego's booking → 403 ─────────────────────
rc, _ = post_json("/kiosk/cancel_booking",
                  { booking_id: diego_booking_id },
                  bearer(TOKEN_B))
record(results, "CrossOwnerCancel", rc == 403, "Bea cancel Diego's booking → #{rc} (want 403)")

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

# ── SelfAssertedTokenForgery (K-539, restated by T-104) ──────────────────────
# THE BEAT SURVIVES ITS TARGET, AND THAT IS THE POINT OF KEEPING IT. Until
# T-104 this demo shipped a hand-copied composite agent-IdP whose cleartext
# fallback parsed `agent:u-…:a-…:r-…` into an identity at whatever role the
# string named — live wherever `Rails.env.local?`, which is exactly the
# environment these drivers run in. The sibling suite could therefore only
# demonstrate the block IN-PROCESS, against a stubbed production `Rails.env`,
# while asserting that development still ACCEPTED the forgery.
#
# The parser is gone rather than gated: agent auth is the engine's own kiosk-pop
# verifier, which has no cleartext branch to fall back to in any environment. So
# the assertion is now unconditional and lands over the LIVE WIRE, in the same
# environment as every other beat here: a self-asserted bearer resolves to NO
# identity. There is no `Rails.env` anywhere in it.
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
  code, = get_json("/kiosk/availability", { party_size: 2 }, bearer(token))
  [code == 401, "#{label} → #{code}"]
end
rc_auth_ctl, = get_json("/kiosk/availability", { party_size: 2 }, bearer(TOKEN_A))
record(results, "SelfAssertedTokenForgery",
       self_asserted.all? { |ok, _| ok } && rc_auth_ctl == 200,
       "self-asserted `agent:u-…:r-owner` bearer: #{self_asserted.map(&:last).join(', ')} " \
       "(want 401 each, unconditionally — this IS a development server); " \
       "CONTROL the earned token → #{rc_auth_ctl} (want 200)")

# ── UnknownQuery — unregistered query name → 404 ─────────────────────────────
rc, _ = get_json("/kiosk/frobnicate", {}, bearer(TOKEN_A))
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = post_json("/kiosk/nope", {}, bearer(TOKEN_A))
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── RetiredWire — the deleted 0.3 endpoints are GONE, not tombstoned ─────────
# T-074 = A was a hard cut. `POST /kiosk/query` now reaches the per-verb
# controller as a verb literally named "query", which nobody registered, so it
# answers the ordinary 404 an AUTHENTICATED caller gets — no privileged
# endpoint, no compatibility payload, no second conformance surface to attack.
#
# BOTH CALLERS ARE PROBED, and that is the whole point of the qualifier above
# (K-1094). `VerbController#serve` resolves the identity BEFORE it looks the
# verb up, so a caller with no bearer never reaches the registry lookup that
# produces the 404 — it is answered 401 `unauthenticated`, exactly as it would
# be at any other name. Every retired-wire beat in the fleet dialled WITH a
# bearer, so seven suites' prose said the 404 flatly while nothing anywhere
# tested the anonymous case the sentence was wrong about.
retired = %w[query run].map do |name|
  rc, body = post_json("/kiosk/#{name}", { name: "availability", party_size: 2 }, bearer(TOKEN_A))
  [rc == 404 && body["code"] == "not_found", "#{name}→#{rc}/#{body['code'].inspect}"]
end
retired_anon = %w[query run].map do |name|
  rc, body = post_json("/kiosk/#{name}", { name: "availability", party_size: 2 })
  [rc == 401 && body["code"] == "unauthenticated", "#{name}(anon)→#{rc}/#{body['code'].inspect}"]
end
record(results, "RetiredWire", (retired + retired_anon).all? { |ok, _| ok },
       "0.3 endpoints #{(retired + retired_anon).map(&:last).join(', ')} " \
       "(want 404/\"not_found\" with a bearer, 401/\"unauthenticated\" without)")

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
#
# THE NEAR END JOINED THE BEAT UNDER K-969 (Phil, 2026-08-23: «there should be
# zero availability for past dates»). The horizon has two ends and only the far
# one was probed: a date BEHIND it is refused by the very same
# {WireArguments.seating_date} guard, because `Seatings.upcoming` starts at
# today in Europe/Lisbon and drops today's already-started seatings — so the
# behaviour was already right and only the assertion was missing. It is added
# here rather than as a beat of its own because it is literally the same guard
# answering the same question from the other side.
#
# «PAST» ON THIS DEMO IS AN INSTANT, NOT A DAY, and that is a real difference
# from hoteling and getgrocery: those sell by the DAY (and both count today as
# bookable), while atablefor sells three named evening SEATINGS, so tonight's
# 19:00 stops being offered at 19:00 while tonight's 21:00 is still bookable.
# The floor is therefore "has this seating started?", read in the restaurant's
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
  ["date=#{PAST_DATE} (valid date, BEHIND the horizon — K-969)",
   { party_size: 2, date: PAST_DATE }, ["upcoming seatings"]],
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

# ── BookOutsideOfferedHorizon (K-767) ────────────────────────────────────────
#
# THE WRITE SIDE OF THE BEAT ABOVE. `availability` refuses an out-of-horizon
# `date` filter; `book_table` used to CONFIRM one. Its only date guard asked
# "has this seating already started?", which a date weeks in the future answers
# NO to, so a booking was written for a (table, seating) `availability` has
# never listed and will not list until the rolling window reaches it (K-767).
#
# TWO LAYERS ANSWER, AND WHICH ONE IS THE POINT OF THE SECOND PROBE. The
# out-of-horizon date reaches the handler guard, because no `enum` written at
# declaration time can name a horizon that rolls forward daily, and the refusal
# NAMES the bookable dates. The basic-ISO spelling — `20260821` rather than
# `2026-08-21` — never gets that far: `book_table` declares `format: "date"`
# and 0.4 validates `input_schema` on every call, so the wire refuses the
# spelling the descriptor does not advertise before any Ruby runs. It is worth
# probing anyway: `Date.iso8601` ACCEPTS the basic form, so the handler alone
# would have parsed it, and this beat is what says the two layers together
# leave no way in.
#
# Both are asserted as a TYPED 400 naming what was wrong — a 500 or a silent
# success fails either one — and the horizon probe additionally has to name the
# dates that WOULD work, which is what an assistant recovers from.
horizon_slot = open_slot
horizon_probes = [
  ["date=#{FAR_FUTURE} (valid date, beyond the rolling horizon)", FAR_FUTURE, "upcoming seatings"],
  # K-969, the near end of the same horizon. The sentence differs from the far
  # end's on purpose and is not this beat's to normalise: a date behind the
  # horizon trips `Seatings.past?` FIRST, so the refusal is «seating … has
  # already started — call availability again for the still-bookable seatings»,
  # which names where a bookable value comes from rather than listing them. Both
  # are typed 400s an assistant recovers from, which is what is asserted.
  ["date=#{PAST_DATE} (valid date, BEHIND the rolling horizon — K-969)",
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
record(results, "BookOutsideOfferedHorizon",
       horizon_probes.all? { |ok, _| ok } && horizon_control_ok,
       "#{horizon_probes.map(&:last).join(', ')}; CONTROL same row at its published date → " \
       "#{rc_horizon_ctl}/#{horizon_ctl['booking_id'].inspect} " \
       "(want 400 bad_request naming the horizon for each, and a confirmed control)")

# ── HostileArgShapes (K-773, K-1027, K-1028) ────────────────────────────────
#
# THIS BATTERY HAD NO SHAPE BEAT AT ALL UNTIL K-1027, which is why the row was
# filed against atablefor rather than found here: every `party_size` in the
# fourteen beats above is the legal `2`. Its siblings have carried one since
# K-773 (hoteling and getgrocery both), so this is the last of the three ORM
# demos to get it.
#
# WHAT IS PROBED, NAMED RATHER THAN CLAIMED (K-773's 2026-08-25 reopen: a beat
# whose comment CLAIMS coverage is itself the defect). Exactly these:
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
#   * `party_size` — BOTH LAYERS REFUSE EVERY SHAPE BELOW, and that sentence is
#     only true since K-1027. {WireArguments.party_size} read a bare `raw.to_i`:
#     `true`, `false`, `[]`, `{}`, `[1]` and `{"a" => 1}` have no `to_i`, so each
#     was a `NoMethodError` → `500 action_failed`, and `1.5.to_i` is 1, so a
#     fractional party was SEATED as a party of one. It goes through
#     {WireArguments.whole_number} now, which is json_schemer's own `integer`
#     (so `2.0` is still a party of two — measured against this demo's bundle).
#     WATCHED FAIL, run and restored: drop `party_size`'s declared `type` from
#     `book_table`'s `input_schema` and these stay 400 off the second layer;
#     with the pre-K-1027 `.to_i` restored underneath the same mutation they are
#     a 500 for the six raising shapes and a CONFIRMED BOOKING for `1.5`.
#     THE SAME MUTATION ON `availability` SAYS SOMETHING ELSE, and it is
#     recorded rather than smoothed over: drop the type there and the QUERY
#     decoder stops coercing, so the guard is handed the raw string `"2"` and
#     refuses a legal party of two — this battery aborts on its first
#     availability call. The second layer is the schema's `integer` exactly, so
#     on the query half it is the DECODER that turns the wire's string into one;
#     independent of the descriptor for `book_table`, downstream of it here.
#   * `restaurant_id` and `restaurant_table_id` — BOTH LAYERS REFUSE EVERY
#     SHAPE BELOW, and that sentence is only true since K-1028; until then this
#     clause said the probes pinned the DESCRIPTOR ALONE, because they did. The
#     declared `{type: "integer", minimum: 1}` answers first; behind it
#     {BookTableOperation}'s own `identifier` routes each through
#     {WireArguments.whole_number} — json_schemer's `integer`, the same one
#     `party_size` uses, so `2.0` still resolves to 2 — and only then asks
#     `>= 1`. It read `restaurant_id.to_i` / `restaurant_table_id.to_i`, the
#     bare `.to_i` `party_size` had just stopped being.
#     NEITHER ARGUMENT HAS A QUERY HALF, which is the one way this pair differs
#     from `party_size`: `book_table` is the only verb on this origin that takes
#     either (`availability` and `my_bookings` only ever RETURN them), so no
#     {Kiosk::Server::ArgumentDecoder} sits anywhere in their path and this
#     second layer is independent of the descriptor on both counts.
#     WATCHED FAIL, run and restored: drop BOTH declared `type`s from
#     `book_table`'s `input_schema` and all 62 probes stay 400 off the second
#     layer; with the pre-K-1028 `.to_i` restored underneath the same mutation
#     TWELVE of them break — the six raising shapes × the two arguments, each a
#     `500 action_failed` LEAKing `NoMethodError`.
#     `1.5` DID NOT BREACH UNDER THAT MUTATION AND THE REASON IS RECORDED
#     RATHER THAN SMOOTHED OVER, because it is the more dangerous half: `.to_i`
#     turned it into 1, and whether resolving to row 1 is a WRONG BOOKING or a
#     400 depends on the SEEDED DATA, not on the guard. This beat's slot is not
#     restaurant 1 table 1, so the mismatch fell out as "no such table 1 at
#     restaurant 2" — a typed refusal naming a table nobody asked for, which is
#     why the probes above stayed green on that value. Measured on the
#     descriptor-less path with the same pre-fix code:
#     `BookTableOperation.call(restaurant_id: 1.5, restaurant_table_id: 1, …)`
#     returned a CONFIRMED BOOKING at restaurant 1 table 1. A probe set cannot
#     pin that half, so the guard has to.
#   * `date` and `time` — the declared `format: "date"` and `enum` answer the
#     non-string shapes; the handler guards behind them ({WireArguments
#     .seating_date}, {WireArguments.seating_time}) read through `to_s`, so they
#     cannot raise but they cannot refuse a shape either.
#   * `booking_id` — the declared `format: "uuid"` answers first;
#     {WireArguments.booking_id}'s `blank?`/`UuidCheck` behind it reads every
#     shape without raising, so this half is two layers for the STRINGS
#     MalformedUuidArg sends and the schema's alone for the container shapes here.
#
# AND THE ERROR BODY MUST NOT CARRY THE RUNTIME'S OWN VOCABULARY: these probes
# are the ones most likely to reach a cast or a `NoMethodError`, so every
# response is checked for the leak strings K-581/K-582 named plus the two
# `NoMethodError` spellings K-773's class-two 500 would have printed.
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
# decoder's `Integer(v, 10)` refuses the STRING `"2.0"` outright. Measured, and
# probed here so that it stays measured — the two halves of the wire are allowed
# to differ, but not silently.
QUERY_JUNK = ["abc", "true", "1.5", "0x10", "", "2.0"].freeze

def shape_verdict(label, rc, body)
  raw  = JSON.generate(body)
  leak = SHAPE_LEAKS.find { |needle| raw.include?(needle) }
  code = body.is_a?(Hash) ? body["code"] : nil
  ok   = rc == 400 && code == "bad_request" && leak.nil?
  [ok, "#{label}→#{rc}/#{code.inspect}#{leak ? " LEAK #{leak}" : ''}"]
end

shape_slot   = open_slot
shape_probes = []

INT_SHAPES.each do |v|
  %i[party_size restaurant_id restaurant_table_id].each do |arg|
    rc, body = book_slot(TOKEN_A, shape_slot, arg => v)
    shape_probes << shape_verdict("book_table #{arg}=#{v.inspect}", rc, body)
  end
end
NONSTRING.each do |v|
  %i[date time].each do |arg|
    rc, body = book_slot(TOKEN_A, shape_slot, arg => v)
    shape_probes << shape_verdict("book_table #{arg}=#{v.inspect}", rc, body)
  end
  rc, body = post_json("/kiosk/cancel_booking", { booking_id: v }, bearer(TOKEN_A))
  shape_probes << shape_verdict("cancel_booking booking_id=#{v.inspect}", rc, body)
end
QUERY_JUNK.each do |v|
  rc, body = get_json("/kiosk/availability", { party_size: v }, bearer(TOKEN_A))
  shape_probes << shape_verdict("availability party_size=#{v.inspect}", rc, body)
end
# The bracket spellings, which URI.encode_www_form cannot produce: they are
# written into the path so Rack's own parser folds them into an Array and a Hash.
["party_size%5B%5D=2", "party_size%5Bx%5D=2"].each do |bracket|
  rc, body = get_json("/kiosk/availability?#{bracket}", {}, bearer(TOKEN_A))
  shape_probes << shape_verdict("availability #{bracket}", rc, body)
end

# ── MAGNITUDE, not type — the axis INT_SHAPES does not have (K-1047) ─────────
#
# Every value in INT_SHAPES varies an argument's TYPE, and nothing above is an
# integer too LARGE for the column behind it. That blind spot is exactly what
# let a sibling demo answer `500 action_failed` for a body its own published
# descriptor called VALID through three hostile-shape waves, so it is closed
# here in the same one.
#
# MEASURED on a booted origin before the bound was declared: `party_size:
# 2_147_483_648` passed `{type: "integer", minimum: 1}` (which had no ceiling),
# passed {WireArguments.party_size} (a whole number >= 1), and reached
# `RestaurantTable.where(capacity.gteq(party_size))` — `capacity` is a
# PostgreSQL `integer` — where ActiveRecord raised `ActiveModel::RangeError`
# CASTING the comparison, on BOTH surfaces that take a party: `book_table`
# (`book_table_operation.rb`) and `availability`
# (`dining_room_controller.rb`). Both answered HTTP 500. `party_size` now
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
shape_probes << shape_verdict("book_table party_size=#{BEYOND_INT4}", rc, body)
rc, body = get_json("/kiosk/availability", { party_size: BEYOND_INT4 }, bearer(TOKEN_A))
shape_probes << shape_verdict("availability party_size=#{BEYOND_INT4}", rc, body)

# Positive controls, one per verb touched, so the beat cannot pass against an
# origin that refuses everything: the SAME availability row books at its
# published values, and the booking it makes cancels.
rc_shape_book, shape_book = book_slot(TOKEN_A, shape_slot)
rc_shape_cancel, = post_json("/kiosk/cancel_booking",
                             { booking_id: shape_book["booking_id"] }, bearer(TOKEN_A))
rc_shape_avail, shape_avail = get_json("/kiosk/availability", { party_size: 2 }, bearer(TOKEN_A))
shape_control_ok = rc_shape_book == 200 && !shape_book["booking_id"].to_s.empty? &&
                   rc_shape_cancel == 200 && rc_shape_avail == 200 && Array(shape_avail).any?
record(results, "HostileArgShapes",
       shape_probes.all? { |ok, _| ok } && shape_control_ok,
       "#{shape_probes.size} probes: #{shape_probes.reject { |ok, _| ok }.map(&:last).join(', ')}" \
       "#{shape_probes.all? { |ok, _| ok } ? 'all 400/"bad_request", no leak' : ''}; " \
       "CONTROLS book→#{rc_shape_book} cancel→#{rc_shape_cancel} availability→#{rc_shape_avail}/" \
       "#{rc_shape_avail == 200 ? Array(shape_avail).size : 0} rows " \
       "(want a typed 400 for every probe, never a 5xx and never a 200, and three live controls)")

# ── DeviceGrantRoleSelfSelection — the SHARED framework beat (K-1128) ────────
#
# The one beat in this file that is NOT hand-rolled: it comes from
# `kiosk-redteam`, so every demo runs the SAME assertion about the
# account-binding claim ceremony and a demo cannot be left out of it by
# forgetting to copy a block.
#
# It exists because the coverage that was supposed to catch K-072 rested on a
# condition nobody re-measured: the shared `PrivilegeSelfSelection` scenario
# probes `/auth/register` only, and the ceremony beats written when K-072 was
# fixed lived in ONE demo's suite. The other six were safe purely because each
# declares a single role — which is exactly the mitigation the ledger row had
# priced K-072 on, and which expired unnoticed the day a demo declared a
# second one.
#
# `declared_roles` names what `config/initializers/kiosk.rb` declares here. The
# scenario ALSO derives a declared role from the wire (the `role` claim of a
# token this origin mints at registration), so a stale list weakens the probe
# rather than emptying it — an invented role was refused by the vulnerable code
# too, which is why a probe that names only one cannot fail.
require "kiosk/redteam"

device_grant_beat    = Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new
device_grant_verdict = device_grant_beat.call(
  Kiosk::Redteam::Client.new(base_url: SERVER),
  Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer]),
)
# A SKIP is recorded as a breach here on purpose: this origin declares a role,
# so "could not test" is a failure of the harness rather than a property of the
# provider, and a silent third state is what let the last one hide.
record(results, device_grant_beat.name, device_grant_verdict.blocked,
       device_grant_verdict.skipped ? "SKIPPED, which this origin must never do — " \
                                      "#{device_grant_verdict.detail}"
                                    : device_grant_verdict.detail)

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
