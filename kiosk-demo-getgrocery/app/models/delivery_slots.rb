# frozen_string_literal: true

# Two-hour delivery windows from 08:00, on the clock of the delivery district.
# Every verb that offers, books, moves or reads a window computes it here.
module DeliverySlots
  FIRST_HOUR   = 8
  WINDOW_HOURS = 2
  COUNT        = 6

  # The origin's zone, used where no address is involved: published examples.
  DEFAULT_ZONE_NAME = "Europe/Dublin"

  module_function

  def default_zone = Time.find_zone!(DEFAULT_ZONE_NAME)

  def zone_for(district) = Time.find_zone!(DublinZones::ZONES.fetch(district))

  def now(zone = default_zone) = zone.now

  # Tomorrow on the origin's clock: every window of it is still bookable.
  def example_date = now.to_date + 1

  # Today, or tomorrow once today's last window has begun.
  def soonest_date(zone)
    today = now(zone).to_date
    bookable_ids(today, zone).empty? ? today + 1 : today
  end

  def slot_at(date, slot_id, zone = default_zone)
    zone.local(date.year, date.month, date.day, FIRST_HOUR + (slot_id - 1) * WINDOW_HOURS)
  end

  # "08:00–10:00 (Europe/Dublin)".
  def label(time, zone = default_zone)
    hour = time.in_time_zone(zone).hour
    format("%02d:00–%02d:00 (%s)", hour, hour + WINDOW_HOURS, zone.name)
  end

  # A window that has begun is no longer bookable.
  def past?(date, slot_id, zone = default_zone, at: Time.current)
    slot_at(date, slot_id, zone) <= at
  end

  def bookable_ids(date, zone = default_zone, at: Time.current)
    (1..COUNT).reject { |slot_id| past?(date, slot_id, zone, at: at) }
  end
end
