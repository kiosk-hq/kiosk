# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for {SalonClock} — the parse
# `book_appointment` reads its `slot` with. Run with:
#   bundle exec rake demo:clock_spec   (or: ruby spec/salon_clock_spec.rb)
#
# THE BUG IT WOULD HAVE CAUGHT, and why the rake task runs this file TWICE.
# The parse used to be stdlib `Time.iso8601`, which binds a string carrying no
# offset to the SERVER PROCESS's zone. The defect is therefore invisible in any
# single run: on the machine that wrote the code the process zone and the zone
# the author meant were the same, and every assertion passed. It only shows when
# the SAME input is parsed under two different `TZ` values and the two answers
# disagree — so section 1 pins the resolved instant to an absolute epoch that no
# process zone can move, and `demo:clock_spec` runs the file under
# `TZ=Etc/GMT-11` and `TZ=Etc/GMT+2`, the two clocks thirteen hours apart that
# the measurement used.
#
# WATCHED FAIL: put `Time.iso8601(str)` back as the return value of
# {SalonClock.parse_slot} and section 1 goes red under both TZ values.

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
puts "  process TZ: #{process_tz}; salon zone: #{SalonClock::ZONE_NAME}"

# ── 1. A ZONELESS SLOT IS THE SALON'S CLOCK, WHATEVER THE PROCESS ZONE IS ────
#
# 2026-09-14 is inside CEST, so 14:00 at the salon is 12:00 UTC. The expected
# value is written as an EPOCH rather than as a rendering: an epoch is the one
# spelling no process zone can quietly reinterpret, which is the whole subject
# of this file.
zoneless = "2026-09-14T14:00:00"
expected = Time.utc(2026, 9, 14, 12, 0, 0).to_i

parsed = SalonClock.parse_slot(zoneless)
assert(parsed.to_i == expected,
       "a zoneless #{zoneless} is 14:00 at the salon (#{expected}), got #{parsed.to_i} (#{parsed.iso8601})")
assert(parsed.utc_offset == 2 * 3600,
       "…and resolves with the salon's summer offset +02:00, got #{parsed.utc_offset / 3600}")

# The same instant, spelled three ways a caller might send it. All three must
# land on ONE epoch: an offset-bearing string is absolute, so it is read the
# same from any clock, and the zoneless one is read at the salon.
{ "with the salon's own offset" => "2026-09-14T14:00:00+02:00",
  "in UTC"                      => "2026-09-14T12:00:00Z",
  "from a caller 13h away"      => "2026-09-15T01:00:00+13:00" }.each do |how, str|
  assert(SalonClock.parse_slot(str).to_i == expected,
         "#{str} (#{how}) is the same instant as the zoneless spelling")
end

# ── 2. WINTER — the zone is a real IANA zone, not a fixed offset ─────────────
winter = SalonClock.parse_slot("2026-01-14T14:00:00")
assert(winter.utc_offset == 3600,
       "in January the salon is on CET (+01:00), got #{winter.utc_offset / 3600} — a fixed offset would say +2")
assert(winter.to_i == Time.utc(2026, 1, 14, 13, 0, 0).to_i,
       "…so a zoneless 14:00 in January is 13:00 UTC, got #{winter.utc.iso8601}")

# ── 3. THE SHAPE GATE — what must still be refused ───────────────────────────
#
# `zone.iso8601` on its own accepts every one of these except the first two:
# "12345" resolves to 2012-12-10 and "2026-09-14" to midnight, and a malformed
# slot that becomes a plausible appointment is worse than one refused by name.
# This is why {SalonClock.parse_slot} keeps stdlib `Time.iso8601` as a shape
# gate whose value it throws away.
["banana", "next tuesday", "12345", "2026-09-14", "", "2026-13-45T99:00:00Z",
 "2026-09-14T14:00", "14:00:00"].each do |bad|
  refused = begin
    SalonClock.parse_slot(bad)
    false
  rescue ArgumentError, TypeError
    true
  end
  assert(refused, "#{bad.inspect} is refused as a slot, not turned into an appointment")
end

# A non-string arrives from a JSON body as an Integer, and must be refused for
# the same reason rather than parsed as an ordinal date.
refused_int = begin
  SalonClock.parse_slot(12_345)
  false
rescue ArgumentError, TypeError
  true
end
assert(refused_int, "a non-string slot (12345) is refused, not read as a date")

# ── 4. THE PUBLISHED EXAMPLE INSTANT IS ON THE SALON'S CLOCK (K-1350) ─────
#
# {BookAppointmentOperation.example_slot} is the one instant this demo publishes
# as «copy this» — the catalog's `example_params`/`example_row` and both `slot`
# refusals read it. It used to render 14:00 UTC, which no guard refuses and no
# caller misresolves; what it demonstrated was a clock the salon does not keep.
#
# WATCHED FAIL: put `(Time.current + 7.days).utc.change(hour: 14).iso8601` back
# and the wall-clock assertion goes red under both TZ values (16 in summer, 15
# in winter), which is the point — the defect is about the SALON's hour, not the
# process's, so a single-TZ run cannot be what catches it.
example = BookAppointmentOperation.example_slot
example_at = SalonClock.parse_slot(example)
assert(example_at.hour == 14,
       "the published example instant is 14:00 at the salon, got #{example_at.hour}:00 (#{example})")
assert(!example.end_with?("Z"),
       "…and it is rendered with the salon's own offset rather than as UTC, got #{example}")
assert(example_at.utc_offset == SalonClock.zone.now.advance(days: 7).utc_offset,
       "…the offset it carries is the salon's own at that instant (DST included), got " \
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
