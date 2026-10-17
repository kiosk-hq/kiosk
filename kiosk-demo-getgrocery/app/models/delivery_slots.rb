# frozen_string_literal: true

# Two-hour delivery windows from 08:00, on the clock of the delivery district.
# Every verb that offers, books, moves or reads a window computes it here.
module DeliverySlots
  FIRST_HOUR   = 8
  WINDOW_HOURS = 2
  COUNT        = 6

  # After payment the shop picks the basket, then the courier drives it over.
  PICKING = 20..30 # minutes
  DRIVE   = 5.minutes

  # The origin's zone, used where no address is involved: published examples.
  DEFAULT_ZONE_NAME = "Europe/Dublin"

  module_function

  def default_zone = Time.find_zone!(DEFAULT_ZONE_NAME)

  # The clock of the address's district; the origin's for an address it does not serve.
  def zone_at(address) = Time.find_zone!(DublinZones::ZONES.fetch(DublinZones.check(address).district, DEFAULT_ZONE_NAME))

  # Today, or tomorrow once today's last window has closed.
  def soonest_date(zone)
    today = zone.today
    bookable(today, zone).empty? ? today + 1 : today
  end

  # Each window's start on `date`, on the clock of `zone`.
  def starts(date, zone = default_zone)
    Array.new(COUNT) { date.in_time_zone(zone).change(hour: FIRST_HOUR + _1 * WINDOW_HOURS) }
  end

  def start?(time, zone) = starts(time.in_time_zone(zone).to_date, zone).include?(time)

  # "08:00–10:00 (Europe/Dublin)".
  def label(time, zone = default_zone)
    hour = time.in_time_zone(zone).hour
    format("%02d:00–%02d:00 (%s)", hour, hour + WINDOW_HOURS, zone.name)
  end

  # A window takes orders while a basket paid now still reaches the door inside it.
  def closed?(slot_at)
    (slot_at + WINDOW_HOURS.hours - PICKING.max.minutes - DRIVE).past?
  end

  def bookable(date, zone) = starts(date, zone).reject { closed?(_1) }

  # "14:35 (Europe/Dublin)".
  def clock_label(time, zone) = "#{time.in_time_zone(zone).strftime("%H:%M")} (#{zone.name})"
end
