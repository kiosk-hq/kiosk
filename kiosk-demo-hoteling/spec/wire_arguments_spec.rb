# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for `app/operations/wire_arguments.rb`
# — the shape guard every hoteling verb opens with. Run with:
#   bundle exec rake demo:wire_args_spec   (or: ruby spec/wire_arguments_spec.rb)
#
# WHY IT IS DB-FREE, and why that is the whole point. All six of hoteling's CI
# tasks (`demo:book`, `demo:isolation`, `demo:redteam`, `demo:schema`,
# `demo:search`, `demo:browse`) need a booted origin, a seeded database and a
# live Equihash toll, so without this file the only executable coverage of
# {WireArguments.integer}'s `max:` arm, of `stay_dates`, `past_stay`,
# `example_check_in`/`example_check_out` and `priceable_total` would be
# `demo:redteam` — and that arm is otherwise reached only through the red-team
# battery. Every one of those is a PURE FUNCTION: no connection, no clock but
# the property's, no state.
#
# WHAT IS ASSERTED. Not "something was refused" — the TYPE and the SHAPE of each
# refusal:
#   • every refusal is an {OperationResult} whose `code` resolves through
#     hoteling's own STATUSES map, so a code this demo never mapped would raise a
#     KeyError here rather than at the wire. `property_not_found` is the one that
#     is NOT a 400, and it is asserted as `not_found`/`:not_found` — the
#     three-way rule (spec §9.1) lives or dies on that distinction;
#   • no hostile shape RAISES. A guard that raises is not a guard — a bare
#     `.to_i` answers `true` and `[]` with a 500;
#   • the SHAPE refusal and the MAGNITUDE refusal are DIFFERENT sentences —
#     `"abc"` is not "out of range", and a caller told the wrong one debugs the
#     wrong thing;
#   • the guard's own header makes claims about who omits `max:` and why there is
#     no `min:`. Those are behaviour, so they are asserted here rather than
#     believed.
#
# WHAT THIS SPEC DOES NOT REACH, stated rather than left to be discovered:
#   • {WireArguments.existing_property} — the ONLY method in the module that
#     touches the database (`Property.exists?`). It is not called here and it is
#     not stubbed: section 9 MEASURES that it is the DB one by showing the bare
#     module cannot resolve `Property` at all, which is a stronger statement
#     than a comment saying so. Its refusal half — {property_not_found}, the
#     sentence and the 404 — has no lookup in it and IS covered, in section 8.
#     What stays uncovered is one `Property.exists?` call, which `demo:redteam`
#     and `demo:book` both exercise against a real origin.
#   • {WireArguments.zone} is asserted to be a real IANA zone, not that Istanbul
#     observes DST — it has not since 2016. What is checkable is that the zone is
#     resolved through tzinfo rather than being a fixed offset, and that is what
#     section 5 asserts.

require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require "date"
require "kiosk/operation_result"

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
#
# THIS HELPER IS BYTE-IDENTICAL to the one in getgrocery's and atablefor's copies
# of this file, deliberately: the three share one harness, and
# bin/check-demo-copies declares this path's shared units and holds them in
# lockstep, so a copy whose body drifted from the other two would go red.
def assert_typed_400(result, label)
  unless result.is_a?(OperationResult)
    return assert(false, "#{label} → an OperationResult, got #{result.class}")
  end

  ok = !result.ok? && result.code == "bad_request" && result.status == :bad_request
  assert(ok, "#{label} → typed 400 (#{result.code.inspect}/#{result.status.inspect}): #{result.message}")
end

# The 404 half, which hoteling alone needs: its WireArguments refuses with TWO
# codes, and the three-way rule (spec §9.1) lives on the distinction.
def assert_typed_404(result, label)
  unless result.is_a?(OperationResult)
    return assert(false, "#{label} → an OperationResult, got #{result.class}")
  end

  ok = !result.ok? && result.code == "not_found" && result.status == :not_found
  assert(ok, "#{label} → typed 404 (#{result.code.inspect}/#{result.status.inspect}): #{result.message}")
end

# The `[value, refusal]` pair this module's two-answer guards answer in.
def refusal_of(pair) = pair.is_a?(Array) ? pair[1] : pair
def value_of(pair)   = pair.is_a?(Array) ? pair[0] : nil

# Freeze the PROPERTY's today, the way spec/wire_arguments_spec.rb does for
# getgrocery's Dublin clock. The original method object is captured FIRST and put
# back from that capture — never re-typed as `zone.now.to_date`, which would be a
# second copy of the implementation pretending to be a restore.
def at_property_date(iso)
  fixed    = Date.iso8601(iso)
  original = WireArguments.method(:today)
  WireArguments.define_singleton_method(:today) { fixed }
  yield fixed
ensure
  WireArguments.define_singleton_method(:today) { original.call }
end

MAX  = WireArguments::MAX_INT4
HINT = WireArguments::HINT_PROPERTY_ID

# ── 1. integer/4 — SHAPE: `Integer(raw, 10)`, and what that accepts ──────────
#
# `Integer(str, 10)` and not `.to_i`: `.to_i` answers 0 for "abc", turning a typo
# into a much quieter wrong answer than a 400. Base 10 is EXPLICIT, so "0x10" is
# refused rather than read as 16 — the one accepted-set claim in this guard's
# header that a reader cannot check by eye.
puts "\n── integer: the shape arm, and the base-10 promise ──"
{
  "42"      => 42,
  "  42  "  => 42,   # surrounding space is tolerated, deliberately
  "+42"     => 42,
  "042"     => 42,   # base given, so a leading zero is NOT octal
  "1_000"   => 1000, # Ruby's own literal spelling, accepted by Integer()
  "-5"      => -5,
  "0"       => 0,
  42        => 42,
  -5        => -5,
}.each do |raw, want|
  pair = guard("integer(#{raw.inspect})") { WireArguments.integer(raw, field: "property_id", hint: HINT) }
  assert(refusal_of(pair).nil? && value_of(pair).eql?(want),
         "integer(#{raw.inspect}) → #{want.inspect} with no refusal, got #{pair.inspect}")
end

# NOT AN INTEGER — the SHAPE sentence, echoing the value and carrying the
# CALLER's hint (a refusal that only says "not an integer" does not say where a
# right one comes from).
["0x10", "1.5", "abc", "12abc", "1e3", "'; DROP TABLE properties; --", true, [1], { "a" => 1 }, 2.0]
  .each do |raw|
  pair    = guard("integer(#{raw.inspect})") { WireArguments.integer(raw, field: "property_id", hint: HINT) }
  refusal = refusal_of(pair)
  assert_typed_400(refusal, "integer(#{raw.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(value_of(pair).nil?, "  … and yields NO value alongside the refusal")
  assert(refusal.message == "property_id #{raw.to_s.inspect} is not an integer",
         "  … the SHAPE sentence echoing the value: #{refusal.message.inspect}")
  assert(refusal.hint == HINT, "  … carries the CALLER's hint verbatim: #{refusal.hint.inspect}")
  leaks = ["ActiveRecord", "PG::", "22P02", "SELECT", "ActiveModel::RangeError"]
          .select { |needle| refusal.message.include?(needle) }
  assert(leaks.empty?, "  … leaks no SQL/PG/runtime internals (found #{leaks.inspect})")
end

# `2.0` IS an integer to the JSON Schema in front of getgrocery's `whole_number`
# and is NOT one here, and that divergence is deliberate: hoteling's integers
# arrive as QUERY STRINGS the engine's ArgumentDecoder has already coerced, so
# this helper's job is to parse a string, not to interpret a JSON number
# (the module header's own claim, asserted rather than believed).
pair = guard("integer(2.0)") { WireArguments.integer(2.0, field: "property_id", hint: HINT) }
assert(refusal_of(pair).is_a?(OperationResult) &&
       refusal_of(pair).message == "property_id \"2.0\" is not an integer",
       "a Float 2.0 is REFUSED here where getgrocery's whole_number accepts it — the two " \
       "coercions diverge on purpose: #{refusal_of(pair)&.message.inspect}")

# ── 2. integer/4 — ABSENT is its own answer (`blank?`), not a shape error ────
#
# `false.blank?`, `[].blank?` and `{}.blank?` are all true, so each of them is
# "you did not give me one" rather than "you gave me the wrong thing". `true` is
# NOT blank, so it lands on the shape arm above. That split is behaviour a caller
# reads, so it is asserted at both ends.
puts "\n── integer: absent is `missing field:`, and blank? decides which ──"
[nil, "", "   ", false, [], {}].each do |raw|
  pair    = guard("integer(#{raw.inspect})") { WireArguments.integer(raw, field: "room_type_id", hint: HINT) }
  refusal = refusal_of(pair)
  assert_typed_400(refusal, "integer(#{raw.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "missing field: room_type_id",
         "  … the ABSENT sentence, not the shape one: #{refusal.message.inspect}")
  assert(refusal.hint.nil?,
         "  … and carries no hint — \"where do I get one\" answers the wrong question here")
end

# ── 3. integer/4 — MAGNITUDE: the `max:` arm ─────────────────────────────────
#
# THE BOUND IS THE COLUMN'S, NOT A POLICY. `min_stars` and `max_price_cents` are
# compared against 4-byte `integer` columns; `gteq(2**31)` is the RAISING shape,
# so without this arm a well-formed argument a client simply got wrong is a 500
# with the runtime's class name in the body.
puts "\n── integer: the magnitude arm, and the ceiling is the column's ──"
[MAX, MAX - 1, 0, -5].each do |raw|
  pair = guard("integer(#{raw}, max: MAX)") do
    WireArguments.integer(raw, field: "max_price_cents", hint: HINT, max: MAX)
  end
  assert(refusal_of(pair).nil? && value_of(pair).eql?(raw),
         "integer(#{raw}, max: #{MAX}) → #{raw} — at or under the ceiling it passes, got #{pair.inspect}")
end

[MAX + 1, 2**40, 2**64, "2147483648"].each do |raw|
  pair    = guard("integer(#{raw.inspect}, max: MAX)") do
    WireArguments.integer(raw, field: "max_price_cents", hint: HINT, max: MAX)
  end
  refusal = refusal_of(pair)
  assert_typed_400(refusal, "integer(#{raw.inspect}, max: #{MAX})")
  next unless refusal.is_a?(OperationResult)

  assert(value_of(pair).nil?, "  … and yields NO value, so nothing reaches the cast")
  assert(refusal.message == "max_price_cents must be <= #{MAX} — got #{raw.to_i}",
         "  … the MAGNITUDE sentence, a different one from the shape refusal: " \
         "#{refusal.message.inspect}")
  assert(refusal.hint == HINT, "  … still carries the caller's hint: #{refusal.hint.inspect}")
end

# THE ARGUMENTS THAT DELIBERATELY PASS NO `max:` — `limit`, `property_id`,
# `room_type_id`. With `max: nil` the same beyond-int4 value is ACCEPTED, which
# is what makes those omissions decisions rather than oversights: `limit` reaches
# no column (it is clamped into 1..HOTELING_SEARCH_MAX two lines on) and the two
# identifiers reach EQUALITY predicates, which ActiveRecord absorbs into "no such
# row" — a 404, which is spec §9.1's second branch and not a 400.
[MAX + 1, 2**64].each do |raw|
  pair = guard("integer(#{raw}, max: nil)") { WireArguments.integer(raw, field: "limit", hint: HINT) }
  assert(refusal_of(pair).nil? && value_of(pair).eql?(raw),
         "integer(#{raw}) with NO ceiling is accepted — `limit`/`property_id`/`room_type_id` " \
         "pass none, and that omission is reasoned in the guard's header, got #{pair.inspect}")
end

# THERE IS NO `min:`, AND THIS IS WHAT THAT MEANS: a value far below -2**31 is
# accepted by this guard. Nothing on this surface has a floor that is the guard's
# to enforce (`min_stars`' 1 and `max_price_cents`' 0 are descriptor policy, a
# negative id equality-matches nothing, `limit` clamps) — so the absence is
# asserted rather than left as a sentence in a comment.
pair = guard("integer(-2147483649, max: MAX)") do
  WireArguments.integer(-2_147_483_649, field: "min_stars", hint: HINT, max: MAX)
end
assert(refusal_of(pair).nil? && value_of(pair).eql?(-2_147_483_649),
       "a value below -2**31 passes: this guard has NO `min:` — a floor here would be policy, " \
       "and the descriptors own policy, got #{pair.inspect}")

# ── 4. stay_dates/2 — `Date.iso8601`, NOT `Date.parse` (the SQLi tail) ───────
#
# `Date.parse` SCANS for a date rather than validating a format, so it accepts
# `"2026-09-01'; --"` and `["2026-09-01"]` — and would turn a refusal into a
# booking. It is also the demo's ONLY date guard: `hotel_detail` calls this one
# rather than keeping a `Date.parse` of its own, so a spelling accepted for a
# stay is accepted for a room list too.
#
# AND THE ACCEPTED SET IS THE ONE THE REFUSAL NAMES. `Date.iso8601` is a FAMILY:
# `"20260901"`, `"2026-09-01T10:00:00Z"`, `"2026-W36-2"` and `"2026-244"` all
# parse to 2026-09-01 where the sentence says "use YYYY-MM-DD" — four
# undocumented spellings on the descriptor-less `ReserveRoomOperation` path, two
# of which resolve to a day nobody reading the booking would recognise and one
# of which silently discards a time. So the strict parse is asserted here, and
# all four spellings are in the refusal battery below.
puts "\n── stay_dates: the strict parse, and both missing halves ──"
[["2026-09-01", "2026-09-04"]].each do |ci, co|
  pair = guard("stay_dates(#{ci.inspect}, #{co.inspect})") { WireArguments.stay_dates(ci, co) }
  assert(refusal_of(pair).nil? && value_of(pair) == [Date.new(2026, 9, 1), Date.new(2026, 9, 4)],
         "stay_dates(#{ci.inspect}, #{co.inspect}) → two Dates — YYYY-MM-DD is the ONE spelling " \
         "this guard takes, and the one its refusal names, got #{value_of(pair).inspect}")
end

# `Date.iso8601` still runs behind the format check: it is what refuses a
# well-shaped date that is not a DAY (`"2026-02-30"`, `"2026-13-01"`).
["2026-09-01'; --", ["2026-09-01"], "2026-9-1", "2026-02-30", "2026-13-01", 42, "tomorrow",
 "01/09/2026", "20260901", "2026-09-01T10:00:00Z", "2026-W36-2", "2026-244"].each do |bad|
  pair    = guard("stay_dates(#{bad.inspect})") { WireArguments.stay_dates(bad, "2026-09-04") }
  refusal = refusal_of(pair)
  assert_typed_400(refusal, "stay_dates(#{bad.inspect}, ok)")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "invalid check_in/check_out: #{bad.to_s.inspect}/\"2026-09-04\" — " \
                            "use YYYY-MM-DD",
         "  … names BOTH halves and the format wanted: #{refusal.message.inspect}")
end

# Both halves are required, and each names ITSELF — a caller that omitted
# check_out must not be told about check_in.
[nil, "", "   ", false].each do |blank|
  refusal = refusal_of(guard("stay_dates(#{blank.inspect}, ok)") do
    WireArguments.stay_dates(blank, "2026-09-04")
  end)
  assert_typed_400(refusal, "stay_dates(#{blank.inspect}, ok)")
  assert(refusal.is_a?(OperationResult) && refusal.message == "missing field: check_in",
         "  … a blank check_in names check_in: #{refusal&.message.inspect}")

  refusal = refusal_of(guard("stay_dates(ok, #{blank.inspect})") do
    WireArguments.stay_dates("2026-09-01", blank)
  end)
  assert_typed_400(refusal, "stay_dates(ok, #{blank.inspect})")
  assert(refusal.is_a?(OperationResult) && refusal.message == "missing field: check_out",
         "  … a blank check_out names check_out: #{refusal&.message.inspect}")
end

# ORDERING IS NOT THIS GUARD'S QUESTION, and the reason is that the nights are
# counted by the caller: a check_out BEFORE the check_in parses fine here and is
# refused where the stay is priced. Asserted so the seam is a decision rather
# than a hole nobody noticed.
pair = guard("stay_dates(reversed)") { WireArguments.stay_dates("2026-09-04", "2026-09-01") }
assert(refusal_of(pair).nil? && value_of(pair) == [Date.new(2026, 9, 4), Date.new(2026, 9, 1)],
       "a reversed pair PARSES here — the night count is the caller's question, not this " \
       "guard's, got #{value_of(pair).inspect}")

# ── 5. today / zone / example_check_in / example_check_out ───────────────────
puts "\n── the property's clock, and the examples read off it ──"
assert(WireArguments::ZONE_NAME == "Europe/Istanbul",
       "the floor is read in the PROPERTY's locale (#{WireArguments::ZONE_NAME}), never the caller's")
assert(WireArguments.zone.is_a?(ActiveSupport::TimeZone),
       "zone is an ActiveSupport::TimeZone, got #{WireArguments.zone.class}")
assert(WireArguments.zone.tzinfo.identifier == "Europe/Istanbul",
       "… resolved through tzinfo — a REAL IANA zone rather than a fixed offset, so a future " \
       "government decision moves it and this code does not: #{WireArguments.zone.tzinfo.identifier}")
assert(WireArguments.today == WireArguments.zone.now.to_date,
       "today IS the property zone's date, read at call time")

at_property_date("2026-03-15") do |fixed|
  assert(WireArguments.today == fixed, "the clock is frozen for this block (#{fixed})")
  assert(WireArguments.example_check_in == fixed + 1,
         "example_check_in is TOMORROW in the property's locale (#{WireArguments.example_check_in}) " \
         "— never a calendar literal, which ages into a 400 the day the floor passes it")
  assert(WireArguments.example_check_out == fixed + 4,
         "example_check_out is example_check_in + 3 (#{WireArguments.example_check_out})")
  assert((WireArguments.example_check_out - WireArguments.example_check_in).to_i == 3,
         "… a THREE-night stay, which is what the example_row beside it prices")
  assert(guard("past_stay(example_check_in)") { WireArguments.past_stay(WireArguments.example_check_in) }.nil?,
         "the published example is BOOKABLE at the same instant it is published — the property " \
         "these examples exist for, asserted against the same floor the verb uses")
end
assert(WireArguments.today == WireArguments.zone.now.to_date,
       "and the real clock is back after the frozen block (#{WireArguments.today})")

# ── 6. past_stay/1 — spec §9.1's FIRST branch, on the property's clock ───────
#
# A past `check_in` is outside the verb's DOMAIN, so `400 bad_request` and never
# `200 []`: the empty array already means SOLD OUT, and only one of those two is
# worth retrying. TODAY IS BOOKABLE — a same-day arrival is an ordinary hotel
# sale, and hoteling models no check-in hour.
puts "\n── past_stay: today is bookable, yesterday is a 400 and not an empty list ──"
at_property_date("2026-03-15") do |fixed|
  [fixed, fixed + 1, fixed + 365].each do |ci|
    assert(guard("past_stay(#{ci})") { WireArguments.past_stay(ci) }.nil?,
           "past_stay(#{ci}) → nil — the floor is the DAY, and today is on the bookable side of it")
  end

  [fixed - 1, fixed - 365].each do |ci|
    refusal = guard("past_stay(#{ci})") { WireArguments.past_stay(ci) }
    assert_typed_400(refusal, "past_stay(#{ci})")
    next unless refusal.is_a?(OperationResult)

    assert(refusal.message == "check_in #{ci.iso8601} is in the past — hoteling sells room-nights " \
                              "from #{fixed.iso8601} onwards (Europe/Istanbul)",
           "  … names the value, the floor AND the zone: #{refusal.message.inspect}")
    assert(refusal.hint.to_s.include?("today IS bookable"),
           "  … says today is bookable, so the caller does not guess: #{refusal.hint}")
    assert(refusal.hint.to_s.include?("EMPTY availability list"),
           "  … and says why this is NOT the sold-out answer: #{refusal.hint}")
  end
end

# THE FLOOR MOVES WITH THE PROPERTY'S CLOCK, not the runner's: the SAME date is
# accepted on one day and refused on the next. Nothing here reads Date.today.
DAY = Date.new(2026, 3, 15)
at_property_date("2026-03-15") do
  assert(WireArguments.past_stay(DAY).nil?, "on #{DAY} in Istanbul, #{DAY} is bookable")
end
at_property_date("2026-03-16") do
  refusal = WireArguments.past_stay(DAY)
  assert(refusal.is_a?(OperationResult) && refusal.message.include?("is in the past"),
         "one property-day later the SAME date is REFUSED, so the clock read is the property's " \
         "and not the caller's: #{refusal&.message.inspect}")
end

# ── 7. priceable_total/2 — a stay nobody can price is a 400, not a 500 ───────
#
# `bookings.total_cents` is a 4-byte integer, so a well-formed ISO check_in far
# enough back used to price a stay past it and the INSERT raised
# ActiveModel::RangeError — HTTP 500 for an argument a client got wrong.
# THE BOUND IS THE COLUMN'S: it invents no booking horizon.
puts "\n── priceable_total: the ceiling is the column's, and the refusal is recoverable ──"
[0, 1, MAX].each do |total|
  assert(guard("priceable_total(#{total}, 3)") { WireArguments.priceable_total(total, 3) }.nil?,
         "priceable_total(#{total}, 3) → nil (the stay can be booked in one reservation)")
end

[[MAX + 1, 4], [2**40, 900], [2**64, 1]].each do |total, nights|
  refusal = guard("priceable_total(#{total}, #{nights})") { WireArguments.priceable_total(total, nights) }
  assert_typed_400(refusal, "priceable_total(#{total}, #{nights})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "a #{nights}-night stay totals #{total} cents, more than this " \
                            "operator can book in one reservation (max #{MAX})",
         "  … names the nights, the total AND the ceiling: #{refusal.message}")
  assert(refusal.hint.to_s.include?("book a shorter stay"),
         "  … carries a RECOVERABLE hint: #{refusal.hint}")
end

assert(WireArguments::MAX_INT4 == 2_147_483_647,
       "MAX_INT4 is PostgreSQL's `integer` ceiling, declared once for the three columns that " \
       "share it: #{WireArguments::MAX_INT4}")

# ── 8. missing/1 and property_not_found/1 — the two canned sentences ─────────
puts "\n── missing / property_not_found: one sentence each, and only ONE of them is a 400 ──"
["check_in", "booking_id", "property_id"].each do |field|
  refusal = WireArguments.missing(field)
  assert_typed_400(refusal, "missing(#{field.inspect})")
  assert(refusal.message == "missing field: #{field}", "  … #{refusal.message.inspect}")
  assert(refusal.hint.nil?, "  … and carries no hint")
end

[7, 999_999, "abc"].each do |id|
  refusal = WireArguments.property_not_found(id)
  # NOT a bad_request: the value is well-formed and inside its declared type —
  # what is absent is the thing it POINTS AT (spec §9.1's second branch).
  assert_typed_404(refusal, "property_not_found(#{id.inspect})")
  assert(refusal.message == "hotel not found: #{id}", "  … #{refusal.message.inspect}")
  assert(refusal.hint.to_s.include?("search_hotels"),
         "  … names where a working property_id comes from: #{refusal.hint}")
end

assert(OperationResult::STATUSES.key?("not_found"),
       "hoteling's own STATUSES map carries not_found — without it the line above would raise a " \
       "KeyError at the wire instead of rendering a 404")

# ── 9. existing_property/1 — the ONE method this spec does not reach ─────────
#
# It is `Property.exists?(id: …)`, the module's only database call. This spec
# does not stub it and does not boot to reach it; instead it MEASURES that it is
# the DB one — in a process where ActiveRecord was never loaded, the constant
# cannot resolve at all. A comment claiming "this one needs the database" would
# age; this fails the moment someone makes it pure and forgets to say so.
puts "\n── existing_property: named, measured, and deliberately not covered here ──"
assert(WireArguments.respond_to?(:existing_property),
       "the module still ships existing_property — if it is gone, this spec's exclusion note is stale")
begin
  WireArguments.existing_property(1)
  assert(false, "existing_property reached a lookup without ActiveRecord — it is no longer the " \
                "DB-touching method, so this spec's coverage note needs rewriting")
rescue NameError => e
  assert(e.message.include?("Property"),
         "existing_property is the DB one, MEASURED: without a boot it cannot resolve `Property` " \
         "(#{e.message.split("\n").first}). Its refusal half is covered in section 8; the lookup " \
         "itself is exercised by demo:redteam and demo:book against a real origin.")
end

# ── 10. The guards run in front of the database, not behind it ──────────────
#
# Every assertion above ran with ActiveRecord never loaded, which is only
# possible if these checks PRECEDE the connection.
puts "\n── the whole module ran with no database ──"
assert(!defined?(ActiveRecord::Base),
       "every guard above answered without ActiveRecord loaded (they precede every cast, every " \
       "comparison and every lock)")

if FAILURES.empty?
  puts "\nWireArguments spec: ALL PASS"
  exit 0
else
  puts "\nWireArguments spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
