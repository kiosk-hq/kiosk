# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for {ReaderClock} — the clock every
# todo on a shared list is read on — and for the one deadline this demo publishes
# as «copy this». Run with:
#   bundle exec rake demo:clock_spec   (or: ruby spec/reader_clock_spec.rb)
#
# WHY IT IS DB-FREE, AND WHY THAT IS THE POINT. Every other task in this demo's
# rake file boots a server against a seeded Postgres, and two of them pay an
# Equihash toll on the way in. So the whole of the executable proof of tudu sat
# behind three services a contributor may not have, for a module that opens no
# connection, reads no row and is a pure function of the value and the zone it
# is handed. This file needs none of the three.
#
# AND WHY THE RAKE TASK RUNS IT TWICE, UNDER TWO `TZ` VALUES. Stdlib
# `Time.iso8601` binds a string carrying no offset to the SERVER PROCESS's zone,
# and a helper that leaks that zone into its answer is invisible from inside a
# single run: on the machine that wrote the code the process zone and the zone
# the author meant were the same, and every assertion passed. It only shows when
# the SAME input is read under two different `TZ` values and the two answers
# disagree — so every expectation below is pinned to an absolute epoch or to an
# explicitly named zone, and `demo:clock_spec` runs the file under
# `TZ=Etc/GMT-11` and `TZ=Etc/GMT+2`, thirteen hours apart and on either side of
# the household's own clock.
#
# WHAT IS DELIBERATELY NOT HERE. {User.public_name} is a pure derivation too and
# it is the strongest privacy claim in this demo, but the method lives on an
# ActiveRecord class whose body calls `devise` and `has_many`, so it cannot be
# loaded without booting Rails; `demo:redteam` reads it over the wire instead.
# The same goes for the projections on {Todo} and {List}: what is pure about
# them is the rendering, and that rendering is {ReaderClock}, which is right
# here.

require "time"
require "active_support"
require "active_support/core_ext/time"
require "active_support/core_ext/object/blank"
require "date"
require "kiosk/server/current_request"

require_relative "../app/models/reader_clock"
# Loads clean without Rails: the class body defines two methods and resolves no
# model constant until one is CALLED, and {AddTodoOperation.example_due_at}
# calls nothing but {ReaderClock}.
require_relative "../app/operations/add_todo_operation"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# Call a helper and never let it raise past this line: on the paths below a
# raise IS a defect, so it is recorded as a failed assertion rather than ending
# the run at the first one.
def guard(label)
  yield
rescue StandardError => e
  FAILURES << "#{label} RAISED #{e.class}: #{e.message}"
  puts "  FAIL  #{label} RAISED #{e.class}: #{e.message}"
  nil
end

process_tz = ENV["TZ"] || "(unset — the machine's own zone)"
TOKYO      = Time.find_zone!("Asia/Tokyo")
MONTREAL   = Time.find_zone!("America/Toronto")
puts "  process TZ: #{process_tz}; household default zone: #{ReaderClock::DEFAULT_ZONE_NAME}"

# ── 1. THE ZONE IS THE READER'S, AND THE HOUSEHOLD'S WHEN NOBODY SAID ───────
#
# The whole argument of this demo's clock: a reminder is «served» wherever the
# person reading it is, a shared list has two of those people, and the wire lets
# each of them declare their own. What can be proved with no request is that
# {ReaderClock.zone} returns the DECLARED zone when there is one and the
# household's when there is not — and that it invents neither.
assert(ReaderClock.zone.name == ReaderClock::DEFAULT_ZONE_NAME,
       "with nothing declared the household's own clock answers, got #{ReaderClock.zone.name}")
Kiosk::Server::CurrentRequest.with(timezone: TOKYO) do
  assert(ReaderClock.zone.name == "Asia/Tokyo",
         "a caller that declared Asia/Tokyo is answered on it, got #{ReaderClock.zone.name}")
end
assert(ReaderClock.zone.name == ReaderClock::DEFAULT_ZONE_NAME,
       "…and the declaration does not outlive the request that made it")

# The fallback is a real IANA zone and not a fixed offset, so it keeps DST. A
# constant spelled `Etc/GMT+0` would pass every assertion above and answer the
# wrong hour for half the year.
jan = ReaderClock.default_zone.parse("2026-01-15T12:00:00").utc_offset
jul = ReaderClock.default_zone.parse("2026-07-15T12:00:00").utc_offset
assert(jan != jul,
       "the household default is a real IANA zone: January #{jan / 3600} vs July #{jul / 3600}")

# ── 2. AN INSTANT IS AN INSTANT ONLY IF IT SAYS SO ──────────────────────────
#
# A `date-time` field takes RFC 3339 and RFC 3339 REQUIRES the offset, so a
# value without one is not a value of the declared type at all. On a SHARED list
# that matters more than anywhere else in this fleet: a deadline completed on
# the writer's clock is read by somebody else on theirs, with nothing on the
# wire to say the two disagree.
zoneless = "2026-09-14T14:00:00"
assert(ReaderClock.zoneless?(zoneless),
       "#{zoneless} carries no offset, so it names no instant")
["2026-09-14T14:00:00+02:00", "2026-09-14T12:00:00Z", "2026-09-14T12:00:00z",
 "2026-09-15T01:00:00+1300", "2026-09-14T12:00:00-05"].each do |ok|
  assert(!ReaderClock.zoneless?(ok), "#{ok} DOES carry an offset, so it names an instant")
end
# A non-String arrives from a JSON body as an Integer or a nil, and both must
# read as «no offset here» rather than raising on the way to the refusal.
[nil, 12_345, "", "banana"].each do |raw|
  answered = guard("zoneless?(#{raw.inspect})") { ReaderClock.zoneless?(raw) }
  assert(answered == true, "#{raw.inspect} names no instant, and asking does not raise")
end

# ── 3. ONE INSTANT, HOWEVER THE CALLER SPELLED IT ───────────────────────────
#
# 2026-09-14 is inside CEST, so 14:00 at a caller two hours east of UTC is 12:00
# UTC. The expected value is written as an EPOCH rather than as a rendering: an
# epoch is the one spelling no process zone can quietly reinterpret, which is
# the whole subject of this file.
expected = Time.utc(2026, 9, 14, 12, 0, 0).to_i
{ "with a +02:00 offset"    => "2026-09-14T14:00:00+02:00",
  "in UTC"                  => "2026-09-14T12:00:00Z",
  "from a caller 13h away"  => "2026-09-15T01:00:00+13:00" }.each do |how, str|
  assert(ReaderClock.parse(str).to_i == expected,
         "#{str} (#{how}) resolves to one epoch, #{expected}")
  # And the same string read for a reader in another city is the SAME epoch: an
  # offset-bearing value is absolute, so the zone decides only how it READS
  # BACK. That is exactly why two housemates can share one `due_at` column.
  assert(ReaderClock.parse(str, TOKYO).to_i == expected,
         "…and is that same epoch when it is read on another housemate's clock")
end

# The zone argument is not decoration: it is the clock the returned value is
# READ on, so a parse that threw it away and handed back the stdlib result would
# answer with the process zone instead.
tokyo_at = guard("parse(…, TOKYO)") { ReaderClock.parse("2026-09-14T12:00:00Z", TOKYO) }
assert(tokyo_at.respond_to?(:time_zone) && tokyo_at.time_zone.name == "Asia/Tokyo",
       "the parsed value is read on the zone it was handed, got " \
       "#{tokyo_at.respond_to?(:time_zone) ? tokyo_at.time_zone.name : tokyo_at.class}")
assert(tokyo_at&.utc_offset == 9 * 3600,
       "…on that zone's own offset and not the process's, got #{tokyo_at&.utc_offset.inspect}")
assert(tokyo_at&.hour == 21,
       "…so that instant is 21:00 for a Tokyo reader, got #{tokyo_at&.hour.inspect}:00")

# AND THIS IS WHY {ReaderClock.zoneless?} IS ASKED FIRST. `parse` alone COMPLETES
# a zoneless value on whichever clock it is handed — it does not refuse one — so
# the offset check in front of it is the only thing standing between a housemate
# and a deadline resolved on somebody else's morning.
completed = guard("parse(a zoneless value, TOKYO)") { ReaderClock.parse(zoneless, TOKYO) }
assert(completed&.hour == 14 && completed&.utc_offset == 9 * 3600,
       "a zoneless value handed to `parse` is COMPLETED, not refused (#{completed&.iso8601}) — " \
       "which is why the offset check runs before it")

# ── 4. THE SHAPE GATE — what must still be refused ──────────────────────────
#
# `zone.iso8601` on its own accepts several of these: "12345" resolves to a date
# in 2012 and "2026-09-14" to midnight, and a malformed deadline that becomes a
# plausible one is worse than one refused by name. This is why {ReaderClock.parse}
# keeps stdlib `Time.iso8601` as a shape gate whose value it throws away.
["banana", "next tuesday", "12345", "2026-09-14", "", "2026-13-45T99:00:00Z",
 "2026-09-14T14:00", "14:00:00", 12_345, nil].each do |bad|
  refused = begin
    ReaderClock.parse(bad)
    false
  rescue ArgumentError, TypeError
    true
  end
  assert(refused, "#{bad.inspect} is refused as a deadline, not turned into one")
end

# ── 5. PUBLISHING IS RENDERING, AND THE ROW NAMES THE CLOCK ─────────────────
#
# One stored instant, two housemates, two strings — and the `timezone` member
# beside it is what lets each of them tell which clock they are looking at.
at = Time.utc(2026, 9, 14, 12, 0, 0)
assert(ReaderClock.publish(at, TOKYO) == "2026-09-14T21:00:00+09:00",
       "a Tokyo reader sees that instant as 21:00+09:00, got #{ReaderClock.publish(at, TOKYO)}")
assert(ReaderClock.publish(at, MONTREAL) == "2026-09-14T08:00:00-04:00",
       "a Montreal reader sees the SAME instant as 08:00-04:00, got #{ReaderClock.publish(at, MONTREAL)}")
assert(ReaderClock.publish(at, TOKYO) != ReaderClock.publish(at, MONTREAL),
       "…so one deadline reads two ways for two housemates, and the row says which")
assert(ReaderClock.publish(at).is_a?(String),
       "publish answers a String, not a TimeWithZone — the bytes on the wire are this " \
       "module's decision and not the JSON encoder's `time_precision`")
assert(ReaderClock.publish(at) == ReaderClock.publish(at, ReaderClock.default_zone),
       "…and with no reader declared it falls back to the household's own clock")
Kiosk::Server::CurrentRequest.with(timezone: TOKYO) do
  assert(ReaderClock.publish(at) == ReaderClock.publish(at, TOKYO),
         "…while a caller that DID declare one is published on it")
end
assert(ReaderClock.publish(nil).nil?,
       "a todo with no deadline publishes nil rather than an epoch or a blank string")

# ── 6. THE LABEL IS THE FIELD A HUMAN HEARS, SO IT NAMES ITS CLOCK ──────────
#
# A bare "14:00" is a wall clock with no clock named, which on a shared list is
# the ambiguity the whole module exists to remove.
assert(ReaderClock.label(at, TOKYO) == "Mon 14 Sep, 21:00 (Asia/Tokyo)",
       "the spoken deadline names the zone it is read on, got #{ReaderClock.label(at, TOKYO).inspect}")
assert(ReaderClock.label(at, MONTREAL) == "Mon 14 Sep, 08:00 (America/Toronto)",
       "…and the other housemate hears their own, got #{ReaderClock.label(at, MONTREAL).inspect}")
assert(ReaderClock.label(at, TOKYO).include?(TOKYO.name),
       "…the zone is NAMED in the label, not merely implied by the hour")
assert(ReaderClock.label(nil).nil?, "no deadline, no label")

# ── 7. WINTER — the household zone is a real zone on the way out too ────────
winter = Time.utc(2026, 1, 14, 12, 0, 0)
assert(ReaderClock.publish(winter, ReaderClock.default_zone) == "2026-01-14T12:00:00+00:00",
       "in January the household clock is +00:00, got " \
       "#{ReaderClock.publish(winter, ReaderClock.default_zone)}")
summer = Time.utc(2026, 7, 14, 12, 0, 0)
assert(ReaderClock.publish(summer, ReaderClock.default_zone) == "2026-07-14T13:00:00+01:00",
       "…and in July it is +01:00, got " \
       "#{ReaderClock.publish(summer, ReaderClock.default_zone)}")

# ── 8. THE PUBLISHED EXAMPLE DEADLINE IS ONE THIS VERB WOULD ACCEPT ─────────
#
# {AddTodoOperation.example_due_at} is the one instant this demo publishes as
# «here is a value that works»: the `due_at` descriptor quotes it and so do both
# of `add_todo`'s `due_at` refusals. An example that the verb itself would refuse
# is worse than no example, and a calendar literal in shipped code goes on saying
# «e.g.» about a day that has gone.
example = AddTodoOperation.example_due_at
example_at = ReaderClock.parse(example)
assert(!ReaderClock.zoneless?(example),
       "the published example CARRIES an offset — the value the descriptor says to copy is one " \
       "this verb would accept, and a zoneless one is refused: #{example}")
assert(example_at.hour == 14,
       "the published example is 14:00 on the household's own clock, got #{example_at.hour}:00 (#{example})")
assert(!example.end_with?("Z"),
       "…and it is rendered with that zone's own offset rather than as UTC, got #{example}")
# Read off the STRING rather than off the parse: `parse` resolves on the
# household zone whatever offset the value carries, so asking the parsed object
# would answer the same for a value rendered in UTC and hide exactly the defect
# the line above is about.
assert(Time.iso8601(example).utc_offset ==
       ReaderClock.default_zone.now.advance(days: 1).utc_offset,
       "…the offset the STRING carries is that zone's own at that instant, DST included, got " \
       "#{Time.iso8601(example).utc_offset / 3600}")
assert(example_at > Time.now,
       "…and it is still in the future, so the deadline it illustrates is one a caller could set")

puts
if FAILURES.empty?
  puts "  reader-clock spec: all assertions passed (TZ=#{process_tz})"
  exit 0
else
  puts "  reader-clock spec: #{FAILURES.length} FAILED (TZ=#{process_tz})"
  FAILURES.each { |f| puts "    - #{f}" }
  exit 1
end
