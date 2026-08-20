# frozen_string_literal: true

# ── Delivery-slot time source of truth (K-470, K-480) ────────────────────────
# BOTH delivery_slots and create_order compute a slot's wall-clock time from the
# SAME (date, slot_id) pair via this one helper, so the day+time an assistant
# sees in delivery_slots is EXACTLY what create_order books and returns. slot_id
# 1 = 08:00, 2 = 10:00, … (two-hour windows). Previously create_order derived
# the date independently (Date.today + 1), so a slot chosen for TODAY came back
# booked for TOMORROW — the two verbs must never disagree on the date.
#
# ZONE (K-480): slot wall-clock times are the OPERATOR's local time — getgrocery
# delivers in Dublin, so "08:00" means 08:00 in Europe/Dublin, and "now" for the
# past-slot filter is also read in Europe/Dublin. We use the real IANA zone (not
# a fixed +1 offset) so IST (UTC+1, summer) and GMT (UTC+0, winter) are both
# handled automatically across DST. Previously slot_at built a NAIVE UTC time
# (`Time.utc(…, 08, …)`), and delivery_slots returned EVERY slot for the date
# with no past-filter — so at 11:00 Dublin it still offered the un-bookable
# 08:00–10:00 window (worse under UTC+3 dev clocks). Now delivery_slots hides
# any of TODAY's slots whose START has already passed in Dublin, and both
# create_order/reschedule_delivery re-validate the chosen slot is not in the past.
module DeliverySlots
  FIRST_HOUR   = 8
  WINDOW_HOURS = 2
  COUNT        = 6

  # The operator's locale. A real IANA zone → DST-correct (IST in summer, GMT in
  # winter); do NOT replace with a fixed offset.
  ZONE_NAME = "Europe/Dublin"

  module_function

  # The operator-locale ActiveSupport::TimeZone (Europe/Dublin).
  def zone
    @zone ||= Time.find_zone!(ZONE_NAME)
  end

  # "Now" in the operator's locale — the reference point for past-slot filtering.
  def now
    zone.now
  end

  # Start-of-slot as a zoned Time in the operator's locale (Europe/Dublin),
  # DST-correct. slot_id is 1..COUNT. Its .iso8601 carries the real offset
  # (+01:00 in summer / +00:00 in winter), so an assistant reads an unambiguous
  # instant, and create_order books EXACTLY this instant.
  def slot_at(date, slot_id)
    hour = FIRST_HOUR + (slot_id.to_i - 1) * WINDOW_HOURS
    zone.local(date.year, date.month, date.day, hour, 0, 0)
  end

  # Has this (date, slot_id) window's START already passed, relative to `at`
  # (default: now in Dublin)? A window that has already begun is no longer
  # bookable as a fresh delivery, so we filter on START (not end): at 11:00 the
  # 08:00–10:00 AND the 10:00–12:00 windows are both gone; 12:00–14:00 stays.
  def past?(date, slot_id, at: now)
    slot_at(date, slot_id) <= at
  end

  # The still-bookable slot_ids for a date, relative to `at` (default: Dublin
  # now): every slot for a FUTURE date; for TODAY only those whose start has not
  # passed. An empty result for today means the last window has begun — the
  # earliest bookable slot is on a later date (correct: today is sold out).
  def bookable_ids(date, at: now)
    (1..COUNT).reject { |slot_id| past?(date, slot_id, at: at) }
  end
end
