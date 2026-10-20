# frozen_string_literal: true

class Restaurant < ApplicationRecord
  # Evening seatings, on the hour, on this restaurant's own clock.
  SEATING_HOURS = [19, 20, 21].freeze

  has_many :restaurant_tables, dependent: :restrict_with_exception
  has_many :bookings,          dependent: :restrict_with_exception

  def self.served_neighborhoods = distinct.order(:neighborhood).pluck(:neighborhood).compact

  # "20:00", as the wire spells a seating time.
  def self.seating_times = SEATING_HOURS.map { format('%02d:00', it) }

  # "Sun 18 Oct, 20:00 (Europe/Lisbon)": the day, the wall clock and the zone it is read on.
  def self.seating_label(seating) = "#{seating.strftime('%a %d %b, %H:%M')} (#{seating.time_zone.name})"

  # Tomorrow's 20:00 seating on the default clock, as the published examples show it.
  def self.example_seating = new.then { it.seating(it.zone.tomorrow, 20) }

  def zone = Time.find_zone!(timezone)

  def seating(date, hour) = date.in_time_zone(zone).change(hour:)

  # One sentence for a caller whose clock differs from the restaurant's now, else nil.
  def timezone_note(caller_zone)
    return if caller_zone.nil?

    gap = zone.now.utc_offset - caller_zone.now.utc_offset
    return if gap.zero?

    hours = format('%g', gap.abs / 3600.0)
    "#{name} runs on #{timezone} time, #{hours} #{hours == '1' ? 'hour' : 'hours'} " \
      "#{gap.positive? ? 'ahead of' : 'behind'} your #{caller_zone.name}. Every date and time here is the restaurant's."
  end

  # The seatings not yet started: tonight's, then the following days'.
  def upcoming_seatings(days: 2)
    (zone.today...(zone.today + days)).flat_map { |date| SEATING_HOURS.map { seating(date, it) } }.select(&:future?)
  end
end
