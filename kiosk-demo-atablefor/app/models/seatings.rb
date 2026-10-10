# frozen_string_literal: true

# The evening seatings on each restaurant's own clock, so the roster rolls
# forward on its own: tonight's, then tomorrow's.
module Seatings
  TIMES = %w[19:00 20:00 21:00].freeze

  # The origin's own clock: it backfills `restaurants.timezone` and dates the
  # published examples.
  DEFAULT_ZONE_NAME = "Europe/Lisbon"

  module_function

  def default_zone = Time.find_zone!(DEFAULT_ZONE_NAME)

  # "20:00 (Europe/Lisbon)"
  def label(time, zone) = "#{time} (#{zone.name})"

  def seating_at(date, time, zone = default_zone) = zone.parse("#{date} #{time}")

  def past?(date, time, zone) = seating_at(date, time, zone).past?

  # The seatings not yet started over the next `days` days, as [date, "HH:MM"] pairs.
  def upcoming(zone:, days: 2)
    (zone.today...zone.today + days).flat_map do |date|
      TIMES.reject { |time| past?(date, time, zone) }.map { |time| [date, time] }
    end
  end
end
