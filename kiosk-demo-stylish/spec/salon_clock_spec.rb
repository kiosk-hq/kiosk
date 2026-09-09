# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for {SalonClock} — the parse
# `book_appointment` reads its `slot` with. Run with:
#   bundle exec rake demo:clock_spec   (or: ruby spec/salon_clock_spec.rb)
#
# THE BUG IT WOULD HAVE CAUGHT, and why the rake task runs this file TWICE.
# Stdlib `Time.iso8601` binds a string carrying no offset to the SERVER
# PROCESS's zone. The defect that follows is invisible in any
# single run: on the machine that wrote the code the process zone and the zone
# the author meant were the same, and every assertion passed. It only shows when
# the SAME input is parsed under two different `TZ` values and the two answers
# disagree — so section 1 pins the resolved instant to an absolute epoch that no
# process zone can move, and `demo:clock_spec` runs the file under
# `TZ=Etc/GMT-11` and `TZ=Etc/GMT+2`, the two clocks thirteen hours apart that
# the measurement used.
#
# WATCHED FAIL: put `Time.iso8601(str)` back as the return value of
# {SalonClock.parse_slot} and section 2 goes red under both TZ values.
#
# AND THE SECOND SUBJECT, since the zone stopped being an origin constant: the
# clock a row is RENDERED on is `salons.timezone`, read off the salon being
# served. What is provable without a database is that every helper honours the
# zone it is handed and invents none, which sections 2 to 4 assert at two real
# zones; that the zone is READ OFF THE SALON needs a row in a table and is
# exercised by demo:roles and demo:redteam against a booted origin.

require "time"
require "active_support"
require "active_support/core_ext/time"
require "date"

require_relative "../app/models/salon_clock"
# Loads clean without Rails: the class body defines methods and resolves no
# model constant until one is CALLED, and {BookAppointmentOperation.example_slot}
# calls nothing but {SalonClock}.
require_relative "../app/operations/book_appointment_operation"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

process_tz = ENV["TZ"] || "(unset — the machine's own zone)"
PARIS      = Time.find_zone!("Europe/Paris")
MONTREAL   = Time.find_zone!("America/Toronto")
puts "  process TZ: #{process_tz}; origin default zone: #{SalonClock::DEFAULT_ZONE_NAME}"

# ── 1. A ZONELESS SLOT IS REFUSED, NOT COMPLETED ─────────────────────────────
#
# An appointment is an INSTANT. A `date-time` field takes RFC 3339 and RFC 3339
# REQUIRES the offset, so a value without one is not a value of the declared
# type at all — one declared type admits one spelling, exactly as for a
# calendar date. It used to be read at the salon, which is defensible only
# while the caller has no way to state its own clock; now that it has, reading
# it at the salon would ignore the very declaration that matters most here.
zoneless = "2026-09-14T14:00:00"
assert(SalonClock.zoneless?(zoneless),
       "#{zoneless} carries no offset, so it names no instant")
["2026-09-14T14:00:00+02:00", "2026-09-14T12:00:00Z", "2026-09-14T12:00:00z",
 "2026-09-15T01:00:00+1300", "2026-09-14T12:00:00-05"].each do |ok|
  assert(!SalonClock.zoneless?(ok), "#{ok} DOES carry an offset, so it names an instant")
end

# ── 2. AN INSTANT IS ONE INSTANT, HOWEVER THE CALLER SPELLED IT ─────────────
#
# 2026-09-14 is inside CEST, so 14:00 at a Paris salon is 12:00 UTC. The
# expected value is written as an EPOCH rather than as a rendering: an epoch is
# the one spelling no process zone can quietly reinterpret, which is the whole
# subject of this file.
expected = Time.utc(2026, 9, 14, 12, 0, 0).to_i
{ "with the salon's own offset" => "2026-09-14T14:00:00+02:00",
  "in UTC"                      => "2026-09-14T12:00:00Z",
  "from a caller 13h away"      => "2026-09-15T01:00:00+13:00" }.each do |how, str|
  assert(SalonClock.parse_slot(str, PARIS).to_i == expected,
         "#{str} (#{how}) resolves to one epoch, #{expected}")
  # And the SAME string read on a different salon's clock is still that instant:
  # an offset-bearing value is absolute, so the zone decides only how it READS
  # BACK — which is exactly why two salons in two cities can share one column.
  assert(SalonClock.parse_slot(str, MONTREAL).to_i == expected,
         "…and is the same epoch read on another salon's clock — the zone is a rendering, not a meaning")
end

# ── 3. THE ZONE IS A PROPERTY OF THE SALON, so the RENDERING follows it ─────
#
# Which is the whole of the rule this demo used to get right by accident: one
# salon was seeded, so one origin constant and a per-salon column produced the
# same bytes. `publish` takes the zone rather than reading one.
at = SalonClock.parse_slot("2026-09-14T12:00:00Z", PARIS)
assert(SalonClock.publish(at, PARIS) == "2026-09-14T14:00:00+02:00",
       "a Paris salon reads that instant as 14:00+02:00, got #{SalonClock.publish(at, PARIS)}")
assert(SalonClock.publish(at, MONTREAL) == "2026-09-14T08:00:00-04:00",
       "a Toronto salon reads the SAME instant as 08:00-04:00, got #{SalonClock.publish(at, MONTREAL)}")
assert(SalonClock.publish(at, PARIS) != SalonClock.publish(at, MONTREAL),
       "…so two salons of one operator publish one booking on two clocks, and the row says which")
assert(SalonClock.publish(at) == SalonClock.publish(at, PARIS),
       "…and with no salon named it falls back to the ORIGIN default, which is what fills the column")

# ── 4. WINTER — the zone is a real IANA zone, not a fixed offset ─────────────
winter = SalonClock.parse_slot("2026-01-14T13:00:00Z", PARIS)
assert(winter.utc_offset == 3600,
       "in January a Paris salon is on CET (+01:00), got #{winter.utc_offset / 3600} — a fixed offset would say +2")
assert(SalonClock.publish(winter, PARIS) == "2026-01-14T14:00:00+01:00",
       "…so that instant reads back as 14:00+01:00, got #{SalonClock.publish(winter, PARIS)}")

# ── 5. THE SHAPE GATE — what must still be refused ───────────────────────────
#
# `zone.iso8601` on its own accepts every one of these except the first two:
# "12345" resolves to 2012-12-10 and "2026-09-14" to midnight, and a malformed
# slot that becomes a plausible appointment is worse than one refused by name.
# This is why {SalonClock.parse_slot} keeps stdlib `Time.iso8601` as a shape
# gate whose value it throws away.
["banana", "next tuesday", "12345", "2026-09-14", "", "2026-13-45T99:00:00Z",
 "2026-09-14T14:00", "14:00:00"].each do |bad|
  refused = begin
    SalonClock.parse_slot(bad, PARIS)
    false
  rescue ArgumentError, TypeError
    true
  end
  assert(refused, "#{bad.inspect} is refused as a slot, not turned into an appointment")
end

# A non-string arrives from a JSON body as an Integer, and must be refused for
# the same reason rather than parsed as an ordinal date.
refused_int = begin
  SalonClock.parse_slot(12_345, PARIS)
  false
rescue ArgumentError, TypeError
  true
end
assert(refused_int, "a non-string slot (12345) is refused, not read as a date")

# ── 6. THE PUBLISHED EXAMPLE INSTANT IS ON A SALON'S CLOCK ─────────────────
#
# {BookAppointmentOperation.example_slot} is the one instant this demo publishes
# as «copy this» — the catalog's `example_params`/`example_row` and both `slot`
# refusals read it. Rendering it in UTC would break no guard and misresolve for
# no caller; it would simply demonstrate a clock the salon does not keep.
#
# WATCHED FAIL: put `(Time.current + 7.days).utc.change(hour: 14).iso8601` back
# and the wall-clock assertion goes red under both TZ values (16 in summer, 15
# in winter), which is the point — the defect is about the SALON's hour, not the
# process's, so a single-TZ run cannot be what catches it.
example = BookAppointmentOperation.example_slot
example_at = SalonClock.parse_slot(example, PARIS)
assert(!SalonClock.zoneless?(example),
       "the published example CARRIES an offset — the value the descriptor says to copy is one " \
       "this verb would accept, and a zoneless one is now refused: #{example}")
assert(example_at.hour == 14,
       "the published example instant is 14:00 on the origin's own clock, got #{example_at.hour}:00 (#{example})")
assert(!example.end_with?("Z"),
       "…and it is rendered with that zone's own offset rather than as UTC, got #{example}")
assert(example_at.utc_offset == SalonClock.default_zone.now.advance(days: 7).utc_offset,
       "…the offset it carries is that zone's own at that instant (DST included), got " \
       "#{example_at.utc_offset / 3600}")
assert(example_at > Time.now,
       "…and it is still in the future, so the guard it illustrates would accept it")

puts
if FAILURES.empty?
  puts "  salon-clock spec: all assertions passed (TZ=#{process_tz})"
  exit 0
else
  puts "  salon-clock spec: #{FAILURES.length} FAILED (TZ=#{process_tz})"
  FAILURES.each { |f| puts "    - #{f}" }
  exit 1
end
