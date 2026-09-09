# frozen_string_literal: true

# ── Rolling-current seatings source of truth ─────────────────────────────────
# atablefor books restaurant tables for EVENING SEATINGS. Instead of seeding
# date-bearing slot rows that go stale on the hosted deploy, the seatings are
# COMPUTED relative to NOW, in the operator's locale (Europe/Lisbon), and the
# already-passed ones are filtered out. When tonight's seatings are all gone,
# the roster rolls to TOMORROW automatically — so `availability` never goes
# stale, yet the tables it offers are FINITE and can legitimately sell out.
#
# A seating is one of three fixed evening times (19:00 early · 20:00 main ·
# 21:00 late), each an ~3h table hold. `book_table` and `availability` derive a
# seating's wall-clock instant from the SAME (date, "HH:MM") pair through this
# one helper, so the day+time an assistant sees is EXACTLY what it books.
#
# ZONE: EVERY method below takes the zone it is to work in, and that zone is
# THE RESTAURANT's — `restaurants.timezone`, a recorded column. A table is
# served where the table is, so an aggregator listing places in two cities
# offers two different rosters at one instant, and reading one clock off the
# ORIGIN would be right only for as long as every listed restaurant is in one
# city. Europe/Lisbon survives as the ORIGIN DEFAULT: what backfills that
# column and what dates a published example, where no restaurant has been
# addressed yet.
#
# A real IANA zone → WET (UTC+0, winter) / WEST (UTC+1, summer) is handled
# automatically across DST. Do NOT replace with a fixed offset.
module Seatings
  # The evening seatings offered, as "HH:MM" in the restaurant's local time.
  TIMES = %w[19:00 20:00 21:00].freeze

  # The ORIGIN's default locale — what `restaurants.timezone` is backfilled
  # from, and the clock a published example is dated on. It is NOT what a
  # request is answered on: that is the restaurant's own column. A real IANA
  # zone → DST-correct; do NOT replace with a fixed offset.
  DEFAULT_ZONE_NAME = "Europe/Lisbon"

  module_function

  # The ORIGIN default as an ActiveSupport::TimeZone (Europe/Lisbon).
  def default_zone
    @default_zone ||= Time.find_zone!(DEFAULT_ZONE_NAME)
  end

  # "Now" on one restaurant's clock — the reference point for past filtering.
  def now(zone = default_zone)
    zone.now
  end

  # THE DAY A PUBLISHED EXAMPLE NAMES: tomorrow, in the operator's own locale.
  #
  # A descriptor's `example_params`/`example_row` say «copy this verbatim», and
  # a calendar literal there stops being true on a day nobody notices — {past?}
  # then refuses the very example the descriptor tells a caller to copy.
  # Tomorrow rather than today because ALL THREE of a future day's seatings are
  # still bookable, while today's example goes wrong at 21:00 Lisbon.
  #
  # Read through a proc from the declaration, never called at class-body load —
  # see {Kiosk::Server::SchemaSlots}.
  def example_date
    now.to_date + 1
  end

  # The seating time a published example names: the MAIN seating, the middle of
  # {TIMES}. A wall-clock "HH:MM" never ages, so this is a constant and not a
  # second resolvable slot — it is here so the example and {example_date} are
  # read from one place.
  def example_time
    TIMES[1]
  end

  # A seating rendered for a HUMAN, with the zone it is written in beside it —
  # "20:00 (Europe/Lisbon)". One place, because every verb that publishes a
  # seating publishes the same sentence, and because a bare "20:00" is a wall
  # clock with no clock named: a caller two hours east reads it as their own
  # evening. `seating_at` has always carried the resolved offset, but an offset
  # is not what anyone says out loud — the IANA name is.
  #
  # The zone is the RESTAURANT's, handed in by the caller: two restaurants of
  # one aggregator can be in two cities, and this string is what says which one
  # a row is written in.
  def label(time, zone = default_zone)
    "#{time} (#{zone.name})"
  end

  # A seating's start as a zoned Time in THE RESTAURANT's locale, DST-correct.
  # `time` is one of TIMES ("19:00"). Its .iso8601 carries the real offset
  # (+01:00 summer / +00:00 winter in Lisbon) so an assistant reads an
  # unambiguous instant and book_table pins EXACTLY this instant.
  def seating_at(date, time, zone = default_zone)
    hour, min = time.split(":").map(&:to_i)
    zone.local(date.year, date.month, date.day, hour, min, 0)
  end

  # Has this (date, time) seating's start already passed, relative to `at`
  # (default: now on THIS restaurant's clock)? A seating that has already begun
  # is no longer bookable, so we filter on START.
  def past?(date, time, zone = default_zone, at: nil)
    seating_at(date, time, zone) <= (at || now(zone))
  end

  # The still-bookable seatings AT ONE RESTAURANT, as [date, "HH:MM"] pairs,
  # starting from that restaurant's today and rolling forward. Today's already-started seatings are dropped; if ALL of
  # today's are gone, only tomorrow's (and beyond) remain. Returns `days`
  # calendar days' worth of upcoming seatings (default 2 → tonight + tomorrow),
  # so the aggregator always has a non-empty upcoming horizon even late at night.
  def upcoming(days: 2, zone: default_zone, at: nil)
    at    = at || now(zone)
    today = at.to_date
    (0...days).flat_map do |offset|
      date = today + offset
      TIMES.reject { |t| past?(date, t, zone, at: at) }.map { |t| [date, t] }
    end
  end

  # Convenience: the SINGLE next upcoming seating [date, "HH:MM"] (soonest not
  # yet started), or nil if none in the horizon. Used by drivers that just want
  # "tonight's next seating".
  def next_seating(zone: default_zone, at: nil)
    upcoming(zone: zone, at: at).first
  end
end
