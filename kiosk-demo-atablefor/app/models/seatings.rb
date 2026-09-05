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
# ZONE: Europe/Lisbon is a REAL IANA zone → WET (UTC+0, winter) / WEST (UTC+1,
# summer) is handled automatically across DST. Do NOT replace with a fixed
# offset. "now" for the past-seating filter is also read in Lisbon local time.
module Seatings
  # The evening seatings offered, as "HH:MM" in the operator's local time.
  TIMES = %w[19:00 20:00 21:00].freeze

  # The operator's locale. A real IANA zone → DST-correct (WEST in summer, WET
  # in winter); do NOT replace with a fixed offset.
  ZONE_NAME = "Europe/Lisbon"

  module_function

  # The operator-locale ActiveSupport::TimeZone (Europe/Lisbon).
  def zone
    @zone ||= Time.find_zone!(ZONE_NAME)
  end

  # "Now" in the operator's locale — the reference point for past filtering.
  def now
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

  # A seating's start as a zoned Time in the operator's locale (Lisbon),
  # DST-correct. `time` is one of TIMES ("19:00"). Its .iso8601 carries the real
  # offset (+01:00 summer / +00:00 winter) so an assistant reads an unambiguous
  # instant and book_table pins EXACTLY this instant.
  def seating_at(date, time)
    hour, min = time.split(":").map(&:to_i)
    zone.local(date.year, date.month, date.day, hour, min, 0)
  end

  # Has this (date, time) seating's start already passed, relative to `at`
  # (default: Lisbon now)? A seating that has already begun is no longer
  # bookable, so we filter on START.
  def past?(date, time, at: now)
    seating_at(date, time) <= at
  end

  # The still-bookable seatings, as [date, "HH:MM"] pairs, starting from today
  # and rolling forward. Today's already-started seatings are dropped; if ALL of
  # today's are gone, only tomorrow's (and beyond) remain. Returns `days`
  # calendar days' worth of upcoming seatings (default 2 → tonight + tomorrow),
  # so the aggregator always has a non-empty upcoming horizon even late at night.
  def upcoming(days: 2, at: now)
    today = at.to_date
    (0...days).flat_map do |offset|
      date = today + offset
      TIMES.reject { |t| past?(date, t, at: at) }.map { |t| [date, t] }
    end
  end

  # Convenience: the SINGLE next upcoming seating [date, "HH:MM"] (soonest not
  # yet started), or nil if none in the horizon. Used by drivers that just want
  # "tonight's next seating".
  def next_seating(at: now)
    upcoming(at: at).first
  end
end
