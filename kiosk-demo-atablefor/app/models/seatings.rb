# frozen_string_literal: true

# The evening seatings, computed from now on each restaurant's own clock, so
# the roster rolls forward on its own: tonight's, then tomorrow's.
module Seatings
  TIMES = %w[19:00 20:00 21:00].freeze

  # The origin's own clock: it backfills `restaurants.timezone` and dates the
  # published examples.
  DEFAULT_ZONE_NAME = "Europe/Lisbon"

  module_function

  def default_zone = Time.find_zone!(DEFAULT_ZONE_NAME)

  def now(zone = default_zone) = zone.now

  # Tomorrow, when every seating is still bookable.
  def example_date = now.to_date + 1

  def example_time = TIMES[1]

  # "20:00 (Europe/Lisbon)"
  def label(time, zone = default_zone) = "#{time} (#{zone.name})"

  def seating_at(date, time, zone = default_zone)
    hour, min = time.split(":").map(&:to_i)
    zone.local(date.year, date.month, date.day, hour, min, 0)
  end

  def past?(date, time, zone = default_zone, at: nil)
    seating_at(date, time, zone) <= (at || now(zone))
  end

  # The seatings not yet started over the next `days` days, as [date, "HH:MM"] pairs.
  def upcoming(days: 2, zone: default_zone, at: nil)
    at ||= now(zone)
    (0...days).flat_map do |offset|
      date = at.to_date + offset
      TIMES.reject { |time| past?(date, time, zone, at: at) }.map { |time| [date, time] }
    end
  end
end
