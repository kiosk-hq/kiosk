# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for `app/operations/wire_arguments.rb`
# — the shape guards atablefor's verbs open with. Run with:
#   bundle exec rake demo:wire_args_spec   (or: ruby spec/wire_arguments_spec.rb)
#
# WHY IT IS DB-FREE, and why that is the whole point (T-137, T-116's row one demo
# over). Before this file, atablefor shipped NO `spec/` at all: every one of its
# CI tasks needs a booted origin, a seeded database and — for half of them — a
# live Equihash toll, so the only executable coverage of `party_size`,
# `whole_number`, `seating_time`, `seating_date`, `neighborhood` and `booking_id`
# was `demo:redteam`. Every one of them is a PURE FUNCTION: no connection, no
# clock, no state. K-1027 and K-1047 each had to boot an origin to prove a table
# about a handful of literal values.
#
# WHAT IS ASSERTED. Not "something was refused" — the TYPE and the SHAPE of each
# refusal:
#   • every refusal is an {OperationResult} with `code == "bad_request"` whose
#     `status` resolves through atablefor's own STATUSES map to `:bad_request`,
#     so a code this demo never mapped would raise a KeyError here rather than at
#     the wire;
#   • no hostile shape RAISES. That is K-1027 itself: `party_size` read a bare
#     `raw.to_i`, and `true`, `false`, `[]`, `{}` have no `to_i` at all — each was
#     a `500 action_failed` for a value the published descriptor already forbids;
#   • the SHAPE refusal, the RANGE-FLOOR refusal and the CEILING refusal are
#     THREE DIFFERENT sentences (K-1027, K-1047) — `1.5` is not "must be >= 1",
#     and a caller told the wrong one debugs the wrong thing;
#   • the accepted shapes are exactly the published `input_schema`'s and nothing
#     looser (JSON Schema's `integer` is numeric, so `2.0` IS one) and nothing
#     stricter.
#
# WHAT THIS SPEC DOES NOT REACH, stated rather than left to be discovered. Every
# method in this module is pure and every one is covered — but two of them take a
# DB-DERIVED collection as an argument, and it is the DERIVATION that stays
# uncovered here:
#   • `seating_date(raw, upcoming)` is given a literal roster; the real
#     `Seatings.upcoming` (which reads the clock and the tables) is exercised by
#     demo:book and demo:redteam.
#   • `neighborhood(raw, served)` is given a literal list; the `SELECT DISTINCT`
#     that produces it lives in the controller and is likewise a booted-origin
#     concern.
# That is the seam the guards were written for: the QUERY is the caller's, the
# REFUSAL is the guard's, and only the second half needs to be this cheap to test.

require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require "date"
require "securerandom"
require "kiosk/operation_result"

require_relative "../app/models/uuid_check"
require_relative "../app/models/seatings"
require_relative "../app/operations/operation_result"
require_relative "../app/operations/wire_arguments"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# Call a guard and never let it raise past this line: a raise IS the defect this
# module exists to prevent, so it is recorded as a failed assertion rather than
# ending the run.
def guard(label)
  yield
rescue StandardError, NoMethodError => e
  FAILURES << "#{label} RAISED #{e.class}: #{e.message}"
  puts "  FAIL  #{label} RAISED #{e.class}: #{e.message}"
  nil
end

# Every refusal in this module is the same TYPE and the same wire shape. Asserted
# once per refusal rather than described once in prose.
def assert_typed_400(result, label)
  unless result.is_a?(OperationResult)
    return assert(false, "#{label} → an OperationResult, got #{result.class}")
  end

  ok = !result.ok? && result.code == "bad_request" && result.status == :bad_request
  assert(ok, "#{label} → typed 400 (#{result.code.inspect}/#{result.status.inspect}): #{result.message}")
end

# The `[value, refusal]` pair every guard in this module answers in.
def refusal_of(pair) = pair.is_a?(Array) ? pair[1] : pair
def value_of(pair)   = pair.is_a?(Array) ? pair[0] : nil

MAX = WireArguments::MAX_INT4

# ── 1. whole_number/1 — JSON Schema's `integer`, in Ruby ─────────────────────
#
# K-1027's table, and deliberately the SAME table getgrocery's spec runs against
# its own byte-identical copy of this method (T-120's fragment territory): draft
# 2020-12 defines `integer` NUMERICALLY, so `2.0` is a valid integer and a bare
# `is_a?(Integer)` would refuse a call the published schema allows. Everything
# else JSON can carry is not a number at all.
puts "\n── whole_number: the schema's `integer` and nothing looser (K-1027) ──"
[
  # [raw, expected]
  [0,                     0],
  [1,                     1],
  [-1,                    -1],
  [2,                     2],
  [MAX,                   MAX],
  [MAX + 1,               MAX + 1],   # RANGE is the caller's question, not this one's
  [2**64,                 2**64],
  [2.0,                   2],         # a JSON `2.0` IS an integer (json_schemer agrees)
  [-3.0,                  -3],
  [1e18,                  10**18],
  [1.5,                   nil],
  [-0.5,                  nil],
  [0.1,                   nil],
  [Float::INFINITY,       nil],       # not finite → not a party
  [-Float::INFINITY,      nil],
  [Float::NAN,            nil],
  ["1",                   nil],       # a STRING is not a number here, deliberately
  ["1.5",                 nil],
  ["01",                  nil],
  ["0x10",                nil],
  ["",                    nil],
  ["abc",                 nil],
  [nil,                   nil],
  [true,                  nil],
  [false,                 nil],       # `||`-style defaulting would read this as absent
  [[],                    nil],
  [[1],                   nil],
  [{},                    nil],
  [{ "a" => 1 },          nil],
  [:two,                  nil],
].each do |raw, want|
  got = guard("whole_number(#{raw.inspect})") { WireArguments.whole_number(raw) }
  assert(got == want && got.class == want.class,
         "whole_number(#{raw.inspect}) → #{want.inspect} (#{want.class}), got #{got.inspect} (#{got.class})")
end

# ── 2. party_size/1 — THREE answers, one per thing that can be wrong ─────────
#
# The one guard on this origin genuinely shared between a query (`availability`)
# and an action (`book_table`): a party that cannot be shown a table cannot be
# booked one either.
puts "\n── party_size: shape, floor and ceiling are three different sentences ──"
[1, 2, 8, MAX, 2.0].each do |raw|
  pair = guard("party_size(#{raw.inspect})") { WireArguments.party_size(raw) }
  assert(refusal_of(pair).nil? && value_of(pair).eql?(raw.to_i),
         "party_size(#{raw.inspect}) → #{raw.to_i} with no refusal, got #{pair.inspect}")
  assert(value_of(pair).is_a?(Integer),
         "  … and the value is an Integer, so `capacity >= party_size` cannot compare a Float")
end

# WRONG SHAPE — including the four values that used to RAISE NoMethodError on a
# bare `.to_i` (K-1027), and `1.5`, which used to be seated as a party of ONE.
[nil, true, false, 1.5, -0.5, "2", "abc", "01", "0x10", "", [], [1], {}, { "a" => 1 }, :sym,
 Float::NAN, Float::INFINITY].each do |raw|
  pair    = guard("party_size(#{raw.inspect})") { WireArguments.party_size(raw) }
  refusal = refusal_of(pair)
  assert_typed_400(refusal, "party_size(#{raw.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(value_of(pair).nil?, "  … and yields NO value alongside the refusal")
  assert(refusal.message == "party_size must be a whole number >= 1 — got #{raw.inspect}",
         "  … the SHAPE sentence echoing the value: #{refusal.message.inspect}")
end

# OUT OF RANGE at the bottom — a DIFFERENT sentence from the shape one, and the
# split is what K-1032 corrected the header about: an ABSENT party gets the shape
# sentence, a zero gets this one.
[0, -1, -8, 0.0, -2.0, -MAX].each do |raw|
  refusal = refusal_of(guard("party_size(#{raw.inspect})") { WireArguments.party_size(raw) })
  assert_typed_400(refusal, "party_size(#{raw.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "party_size must be >= 1",
         "  … the RANGE FLOOR, with no value echoed: #{refusal.message.inspect}")
end

# OUT OF RANGE at the top (K-1047) — `bookings.party_size` and
# `restaurant_tables.capacity` are 4-byte integers, and it is the COMPARISON that
# casts: `capacity.gteq(2**31)` raised ActiveModel::RangeError, i.e. HTTP 500 for
# an argument a client simply got wrong, on BOTH surfaces at once.
[MAX + 1, 2**40, 2**64, 1e18, (MAX + 1).to_f].each do |raw|
  refusal = refusal_of(guard("party_size(#{raw.inspect})") { WireArguments.party_size(raw) })
  assert_typed_400(refusal, "party_size(#{raw.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "party_size must be <= #{MAX} — got #{raw.to_i}",
         "  … the CEILING sentence, naming the bound and the value: #{refusal.message.inspect}")
end

assert(WireArguments::MAX_INT4 == 2_147_483_647,
       "MAX_INT4 is PostgreSQL's `integer` ceiling — the bound is the COLUMN's and not a house " \
       "limit on party size (K-968's rule): #{WireArguments::MAX_INT4}")

# ── 3. missing_party_size/0 — the fourth question, asked one layer up ────────
puts "\n── missing_party_size: `availability` asks whether the argument was GIVEN ──"
refusal = WireArguments.missing_party_size
assert_typed_400(refusal, "missing_party_size")
assert(refusal.message == "missing param: party_size",
       "  … its own sentence, distinct from the shape one a nil reaches: #{refusal.message.inspect}")
assert(refusal.message != "party_size must be a whole number >= 1 — got nil",
       "  … and the two are NOT the same string, which is the whole reason both exist")

# ── 4. seating_time/1 — a closed set, and absent means "no filter" ───────────
#
# K-717's house rule: a value this origin cannot serve is refused 400 with the
# servable ones NAMED, because `200 []` is indistinguishable from an honest
# sell-out. `time` is also declared as an `enum`, so this is defence in depth for
# the Operations, which reach these guards with no descriptor in between.
puts "\n── seating_time: the roster is named in the refusal (K-717) ──"
Seatings::TIMES.each do |t|
  pair = guard("seating_time(#{t.inspect})") { WireArguments.seating_time(t) }
  assert(refusal_of(pair).nil? && value_of(pair) == t,
         "seating_time(#{t.inspect}) → #{t.inspect} — a seating this restaurant offers")
end

# ABSENT is not a refusal: an empty filter means "any seating", which is how
# `availability` is called with no `time`.
["", nil].each do |blank|
  pair = guard("seating_time(#{blank.inspect})") { WireArguments.seating_time(blank) }
  assert(refusal_of(pair).nil? && value_of(pair) == "",
         "seating_time(#{blank.inspect}) → \"\" with no refusal — an absent filter filters " \
         "nothing, got #{pair.inspect}")
end

["18:00", "22:00", "19:00 ", "19:0", 19, [], {}, false, "'; DROP TABLE bookings; --"].each do |bad|
  refusal = refusal_of(guard("seating_time(#{bad.inspect})") { WireArguments.seating_time(bad) })
  assert_typed_400(refusal, "seating_time(#{bad.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "time #{bad.to_s.inspect} is not a seating — this restaurant seats " \
                            "at #{Seatings::TIMES.join(", ")}",
         "  … echoes the value and NAMES the servable set: #{refusal.message.inspect}")
end

# ── 5. seating_date/2 — the rolling horizon no `enum` can name ───────────────
#
# The horizon rolls forward daily, so no enum written at declaration time can
# name it and `format: "date"` can only say the string is a calendar date. The
# roster is passed IN — this guard reads no clock and no table.
puts "\n── seating_date: the upcoming days, named in the refusal (K-717, T-090) ──"
UPCOMING = [[Date.new(2026, 9, 1), "19:00"],
            [Date.new(2026, 9, 1), "20:00"],
            [Date.new(2026, 9, 2), "19:00"]].freeze
DATES = %w[2026-09-01 2026-09-02].freeze

DATES.each do |d|
  pair = guard("seating_date(#{d.inspect})") { WireArguments.seating_date(d, UPCOMING) }
  assert(refusal_of(pair).nil? && value_of(pair) == d,
         "seating_date(#{d.inspect}) → #{d.inspect} — a day the roster offers")
end

["", nil].each do |blank|
  pair = guard("seating_date(#{blank.inspect})") { WireArguments.seating_date(blank, UPCOMING) }
  assert(refusal_of(pair).nil? && value_of(pair) == "",
         "seating_date(#{blank.inspect}) → \"\" with no refusal — no date filter, got #{pair.inspect}")
end

["2026-09-03", "2026-08-31", "abc", "2026-9-1", 42, [], false, "2026-09-01T19:00:00Z"].each do |bad|
  refusal = refusal_of(guard("seating_date(#{bad.inspect})") { WireArguments.seating_date(bad, UPCOMING) })
  assert_typed_400(refusal, "seating_date(#{bad.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "date #{bad.to_s.inspect} is not among the upcoming seatings — " \
                            "currently #{DATES.join(", ")}",
         "  … names the days that ARE bookable, so the caller recovers without a second fetch: " \
         "#{refusal.message.inspect}")
end

# The roster is de-duplicated: two seatings on one day name that day ONCE.
assert(WireArguments.seating_date("nope", UPCOMING)[1].message.scan("2026-09-01").size == 1,
       "a day with two seatings is named once in the refusal, not once per seating")

# ── 6. neighborhood/2 — a DB-derived set, held at arm's length ───────────────
#
# An operator adds a neighbourhood by inserting a restaurant, so no static `enum`
# can name the set and this guard is the only place the refusal can live (T-090).
# The set arrives as an ARGUMENT, which is exactly why this is testable with no
# database.
puts "\n── neighborhood: the served set is passed IN, so the guard stays pure ──"
SERVED = %w[Alfama Chiado Príncipe\ Real].freeze

SERVED.each do |n|
  pair = guard("neighborhood(#{n.inspect})") { WireArguments.neighborhood(n, SERVED) }
  assert(refusal_of(pair).nil? && value_of(pair) == n,
         "neighborhood(#{n.inspect}) → #{n.inspect} — one this aggregator serves")
end

["", nil].each do |blank|
  pair = guard("neighborhood(#{blank.inspect})") { WireArguments.neighborhood(blank, SERVED) }
  assert(refusal_of(pair).nil? && value_of(pair) == "",
         "neighborhood(#{blank.inspect}) → \"\" with no refusal — no filter, got #{pair.inspect}")
end

["Belem", "alfama", "ALFAMA", 42, [], false, "'; DROP TABLE restaurants; --"].each do |bad|
  refusal = refusal_of(guard("neighborhood(#{bad.inspect})") { WireArguments.neighborhood(bad, SERVED) })
  assert_typed_400(refusal, "neighborhood(#{bad.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "neighborhood #{bad.to_s.inspect} is not one this aggregator " \
                            "serves — currently #{SERVED.join(", ")}",
         "  … names the served set: #{refusal.message.inspect}")
end

assert(WireArguments.neighborhood("alfama", SERVED)[1].is_a?(OperationResult),
       "the match is EXACT, not case-folded — the value goes into a `where` and Postgres would " \
       "not fold it either")

# ── 7. booking_id/1 — PRESENT, then shaped like an id (K-581/K-582, K-654) ───
#
# ActiveRecord does not refuse a malformed uuid, it CASTS it to NULL, so the
# owner-scoped query matches nothing and a TYPO comes back as an OWNERSHIP
# refusal (403) rather than a shape one (400). A well-formed but foreign id still
# gets the 403, so the shape check never softens the ownership answer.
puts "\n── booking_id: absent and malformed are two different sentences ──"
20.times do
  id   = SecureRandom.uuid
  pair = guard("booking_id(#{id})") { WireArguments.booking_id(id) }
  assert(refusal_of(pair).nil? && value_of(pair) == id,
         "booking_id accepts a SecureRandom.uuid verbatim (#{id})")
end

pair = guard("booking_id(upcase)") { WireArguments.booking_id("3F0C1A2E-4B5D-6E7F-8A9B-0C1D2E3F4A5B") }
assert(refusal_of(pair).nil?, "booking_id accepts an UPPER-CASE uuid (Postgres does)")

# BLANK — "you did not give me one". `false.blank?`, `[].blank?` and `{}.blank?`
# are all true, which is why each of them lands here rather than on the shape arm.
[nil, "", "   ", false, [], {}].each do |blank|
  refusal = refusal_of(guard("booking_id(#{blank.inspect})") { WireArguments.booking_id(blank) })
  assert_typed_400(refusal, "booking_id(#{blank.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "missing field: booking_id",
         "  … the ABSENT sentence, not the shape one: #{refusal.message.inspect}")
end

# PRESENT AND MALFORMED — "you gave me the wrong thing", and the sentence names
# where a right one comes from.
[
  "not-a-uuid",
  "'; DROP TABLE bookings; --",
  "12345",
  "3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5",   # one hex digit short
  "3f0c1a2e4b5d6e7f8a9b0c1d2e3f4a5b",      # un-hyphenated: Postgres-legal, not canonical
  " 3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5b", # leading space
  "urn:uuid:3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5b",
  true,
  12_345,
  { "a" => 1 },
].each do |bad|
  pair    = guard("booking_id(#{bad.inspect})") { WireArguments.booking_id(bad) }
  refusal = refusal_of(pair)
  assert_typed_400(refusal, "booking_id(#{bad.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(value_of(pair).nil?, "  … and yields NO value alongside the refusal")
  assert(refusal.message == "booking_id #{bad.to_s.inspect} is not a uuid — pass the " \
                            "`booking_id` that book_table returned (also listed by my_bookings)",
         "  … echoes the value and says where a working one comes from: #{refusal.message.inspect}")

  leaks = ["::uuid", "PG::", "ActiveRecord", "22P02", "SELECT", "invalid input syntax"]
          .select { |needle| refusal.message.include?(needle) }
  assert(leaks.empty?, "  … leaks no SQL/PG internals (found #{leaks.inspect})")
end

# ── 8. The guards run in front of the database, not behind it ──────────────
#
# Every assertion above ran with ActiveRecord never loaded, which is only
# possible if these checks PRECEDE the connection — the property K-1027 and
# K-1047 both had to boot an origin to demonstrate.
puts "\n── the whole module ran with no database ──"
assert(!defined?(ActiveRecord::Base),
       "every guard above answered without ActiveRecord loaded (they precede every cast, every " \
       "comparison and every lock)")

if FAILURES.empty?
  puts "\nWireArguments T-137 spec: ALL PASS"
  exit 0
else
  puts "\nWireArguments T-137 spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
