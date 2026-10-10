# frozen_string_literal: true

class Restaurant < ApplicationRecord
  # Evening seatings, on the hour, on this restaurant's own clock.
  SEATING_HOURS = [19, 20, 21].freeze

  has_many :restaurant_tables, dependent: :restrict_with_exception
  has_many :bookings,          dependent: :restrict_with_exception

  def self.served_neighborhoods = distinct.order(:neighborhood).pluck(:neighborhood).compact

  # "20:00", as the wire spells a seating time.
  def self.seating_times = SEATING_HOURS.map { format("%02d:00", _1) }

  # "20:00 (Europe/Lisbon)": the wall clock and the zone it is read on.
  def self.seating_label(seating) = "#{seating.strftime("%H:%M")} (#{seating.time_zone.name})"

  def zone = Time.find_zone!(timezone)

  def seating(date, hour) = date.in_time_zone(zone).change(hour:)

  # The seatings not yet started: tonight's, then the following days'.
  def upcoming_seatings(days: 2)
    (zone.today...zone.today + days).flat_map { |date| SEATING_HOURS.map { seating(date, _1) } }.select(&:future?)
  end
end
