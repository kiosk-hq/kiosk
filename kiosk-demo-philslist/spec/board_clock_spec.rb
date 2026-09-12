# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for {BoardClock} — the clock a
# listing's publication time is read on. Run with:
#   bundle exec rake demo:clock_spec   (or: ruby spec/board_clock_spec.rb)
#
# WHY IT IS DB-FREE, AND WHY THAT IS THE POINT. Every other task in this demo's
# rake file boots a server against a seeded Postgres, and `demo:register` pays
# an Equihash toll on the way in. So the whole executable proof of this board
# sat behind three services a contributor may not have — for a module that opens
# no connection, reads no row, and is a pure function of the instant and the
# zone it is handed.
#
# WHAT THE MODULE CLAIMS, AND WHAT CAN BE PROVED WITHOUT A REQUEST. A classified
# ad is not delivered anywhere, so «when was this posted» is a question the
# READER asks about their own day: the publication instant is rendered in the
# zone the caller declares, and the row names that zone so a reader can always
# tell which clock they are looking at. `browse_listings` and `my_listings` both
# render every `posted_at` through here. What is provable with no origin is that
# the module honours the zone it is handed, invents none, and falls back to the
# board's own only when nobody declared one — sections 1 to 4. That the header
# reaches it is `demo:redteam` and `demo:walkthrough`, over the wire.
#
# AND WHY THE RAKE TASK RUNS IT TWICE, UNDER TWO `TZ` VALUES. A helper that
# leaks the SERVER PROCESS's zone into its answer is invisible from inside a
# single run: on the machine that wrote the code the process zone and the zone
# the author meant were the same, and every assertion passed. It only shows when
# the same input is read under two different `TZ` values and the two answers
# disagree — so every expectation below is pinned to an absolute instant or to
# an explicitly named zone, and `demo:clock_spec` runs the file under
# `TZ=Etc/GMT-11` and `TZ=Etc/GMT+2`, thirteen hours apart and on either side of
# the board's own clock.
#
# WHAT IS DELIBERATELY NOT HERE. {User.public_handle} — the seller pseudonym,
# and the strongest privacy claim on this board — is a pure derivation too, but
# the method lives on an ActiveRecord class whose body calls `devise` and
# `has_many`, so it cannot be loaded without booting Rails. `demo:redteam`'s
# open-board beat asserts it over the wire instead.

require "time"
require "active_support"
require "active_support/core_ext/time"
require "date"
require "kiosk/server/current_request"

require_relative "../app/models/board_clock"

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
TOKYO      = Time.find_zone!("Asia/Tokyo")
MONTREAL   = Time.find_zone!("America/Toronto")
puts "  process TZ: #{process_tz}; board default zone: #{BoardClock::DEFAULT_ZONE_NAME}"

# ── 1. THE ZONE IS THE READER'S, AND THE BOARD'S WHEN NOBODY SAID ───────────
#
# The declared fallback is a declared fallback: it answers a caller that told us
# nothing, and it is never what a caller that DID declare a zone gets.
assert(BoardClock.zone.name == BoardClock::DEFAULT_ZONE_NAME,
       "with nothing declared the board's own clock answers, got #{BoardClock.zone.name}")
Kiosk::Server::CurrentRequest.with(timezone: TOKYO) do
  assert(BoardClock.zone.name == "Asia/Tokyo",
         "a caller that declared Asia/Tokyo is answered on it, got #{BoardClock.zone.name}")
end
assert(BoardClock.zone.name == BoardClock::DEFAULT_ZONE_NAME,
       "…and the declaration does not outlive the request that made it")

# The fallback is a real IANA zone and not a fixed offset, so it keeps DST. A
# constant spelled `Etc/GMT+0` would satisfy every assertion above and print the
# wrong hour for half the year.
jan = BoardClock.default_zone.parse("2026-01-15T12:00:00").utc_offset
jul = BoardClock.default_zone.parse("2026-07-15T12:00:00").utc_offset
assert(jan != jul,
       "the board default is a real IANA zone: January #{jan / 3600} vs July #{jul / 3600}")
assert(BoardClock.default_zone.equal?(BoardClock.default_zone),
       "…and it is resolved once rather than looked up per row")

# ── 2. ONE INSTANT, TWO READERS, TWO STRINGS ────────────────────────────────
#
# The board is cross-owner and its readers are anywhere, so the same row is
# published on as many clocks as there are readers asking. What must NOT move is
# the instant: «newest first» has to mean the same order to every one of them.
at = Time.utc(2026, 9, 14, 12, 0, 0)
assert(BoardClock.publish(at, TOKYO) == "2026-09-14T21:00:00+09:00",
       "a Tokyo reader sees that instant as 21:00+09:00, got #{BoardClock.publish(at, TOKYO)}")
assert(BoardClock.publish(at, MONTREAL) == "2026-09-14T08:00:00-04:00",
       "a Montreal reader sees the SAME instant as 08:00-04:00, got #{BoardClock.publish(at, MONTREAL)}")
assert(BoardClock.publish(at, TOKYO) != BoardClock.publish(at, MONTREAL),
       "…so one posting reads two ways for two readers, and the row names which")
assert(Time.iso8601(BoardClock.publish(at, TOKYO)).to_i ==
       Time.iso8601(BoardClock.publish(at, MONTREAL)).to_i,
       "…while the two strings name ONE epoch, which is what keeps «newest first» an order")

# ── 3. THE RENDERING IS THIS MODULE'S DECISION, NOT THE ENCODER'S ───────────
#
# A String and not an `ActiveSupport::TimeWithZone`: a TimeWithZone renders
# through `Time.zone` and the JSON encoder's `time_precision`, so the published
# bytes would be the app's configuration talking rather than this file.
published = BoardClock.publish(at, TOKYO)
assert(published.is_a?(String), "publish answers a String, got #{published.class}")
assert(published.end_with?("+09:00"),
       "…carrying the reader's own offset rather than a `Z`, got #{published}")
assert(BoardClock.publish(nil).nil?,
       "an absent instant publishes nil rather than an epoch or a blank string")

# ── 4. THE DEFAULT ARGUMENT FOLLOWS THE REQUEST ─────────────────────────────
#
# Both handlers read the zone once and hand it to every row, but the default
# argument has to agree with them: a `publish` that quietly rendered on the
# board's clock while the handler published the caller's `timezone` beside it
# would put a lie in every row and break no other assertion.
assert(BoardClock.publish(at) == BoardClock.publish(at, BoardClock.default_zone),
       "with nothing declared, publish renders on the board's own clock")
Kiosk::Server::CurrentRequest.with(timezone: TOKYO) do
  assert(BoardClock.publish(at) == BoardClock.publish(at, TOKYO),
         "…and with a declared zone it renders on THAT one, not on the fallback")
  assert(BoardClock.publish(at) != BoardClock.publish(at, BoardClock.default_zone),
         "…which is a visible difference here, not a distinction without one")
end

# ── 5. WINTER AND SUMMER ON THE BOARD'S OWN CLOCK ───────────────────────────
#
# The fallback zone is the one a reader who declared nothing gets, so its DST
# behaviour is published bytes rather than an internal detail.
winter = Time.utc(2026, 1, 14, 12, 0, 0)
assert(BoardClock.publish(winter, BoardClock.default_zone) == "2026-01-14T12:00:00+00:00",
       "in January the board clock is +00:00, got " \
       "#{BoardClock.publish(winter, BoardClock.default_zone)}")
summer = Time.utc(2026, 7, 14, 12, 0, 0)
assert(BoardClock.publish(summer, BoardClock.default_zone) == "2026-07-14T13:00:00+01:00",
       "…and in July it is +01:00, got " \
       "#{BoardClock.publish(summer, BoardClock.default_zone)}")

puts
if FAILURES.empty?
  puts "  board-clock spec: all assertions passed (TZ=#{process_tz})"
  exit 0
else
  puts "  board-clock spec: #{FAILURES.length} FAILED (TZ=#{process_tz})"
  FAILURES.each { |f| puts "    - #{f}" }
  exit 1
end
