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

  def zone_for(district) = Time.find_zone!(DublinZones::ZONES.fetch(district))



  # Today, or tomorrow once today's last window has closed.
  def soonest_date(zone)
    today = zone.today
    bookable_ids(today, zone).empty? ? today + 1 : today
  end

  def slot_at(date, slot_id, zone = default_zone)
    date.in_time_zone(zone).change(hour: FIRST_HOUR + (slot_id - 1) * WINDOW_HOURS)
  end

  # "08:00–10:00 (Europe/Dublin)".
  def label(time, zone = default_zone)
    hour = time.in_time_zone(zone).hour
    format("%02d:00–%02d:00 (%s)", hour, hour + WINDOW_HOURS, zone.name)
  end

  # A window takes orders while a basket paid now still reaches the door inside it.
  def closed?(date, slot_id, zone)
    (slot_at(date, slot_id, zone) + WINDOW_HOURS.hours - PICKING.max.minutes - DRIVE).past?
  end

  def bookable_ids(date, zone)
    (1..COUNT).reject { |slot_id| closed?(date, slot_id, zone) }
  end

  # "14:35 (Europe/Dublin)".
  def clock_label(time, zone) = "#{time.in_time_zone(zone).strftime("%H:%M")} (#{zone.name})"
end
