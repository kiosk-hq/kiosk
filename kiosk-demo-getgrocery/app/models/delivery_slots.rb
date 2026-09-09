# frozen_string_literal: true

# ── Delivery-slot time source of truth ───────────────────────────────────────
# BOTH delivery_slots and create_order compute a slot's wall-clock time from the
# SAME (date, slot_id) pair via this one helper, so the day+time an assistant
# sees in delivery_slots is EXACTLY what create_order books and returns. slot_id
# 1 = 08:00, 2 = 10:00, … (two-hour windows). Deriving the date independently
# in create_order (`Date.today + 1`) books a slot chosen for TODAY as
# TOMORROW — the two verbs must never disagree on the date.
#
# ZONE: a delivery happens AT THE DOOR, so a window's wall clock belongs to the
# DELIVERY ADDRESS — the served district it routed to, whose zone is declared in
# {DublinZones::ZONES}. Every method below TAKES the zone it is to work in
# rather than reading one, and the caller has the district in hand. Every
# district getgrocery serves is in Dublin today, so the answers are unchanged;
# what changes is where they are read FROM, and an operator that opened a depot
# elsewhere would add one row to that map rather than editing a verb.
#
# `Europe/Dublin` survives here as the ORIGIN DEFAULT: what dates a published
# example, which addresses no district. A real IANA zone (not a fixed +1 offset)
# so IST (UTC+1, summer) and GMT (UTC+0, winter) are both handled automatically
# across DST. A NAIVE UTC `slot_at` (`Time.utc(…, 08, …)`) with no past-filter
# would offer the un-bookable 08:00–10:00 window at 11:00 Dublin, and worse under
# UTC+3 dev clocks. So delivery_slots hides any of TODAY's slots whose START has
# already passed at the address, and both create_order/reschedule_delivery
# re-validate the chosen slot is not in the past.
module DeliverySlots
  FIRST_HOUR   = 8
  WINDOW_HOURS = 2
  COUNT        = 6

  # The ORIGIN's default locale — what dates a published example. It is NOT
  # what a request is answered on: that is the delivery district's own zone. A
  # real IANA zone → DST-correct; do NOT replace with a fixed offset.
  DEFAULT_ZONE_NAME = "Europe/Dublin"

  module_function

  # The ORIGIN default as an ActiveSupport::TimeZone (Europe/Dublin).
  def default_zone
    @default_zone ||= Time.find_zone!(DEFAULT_ZONE_NAME)
  end

  # The clock a delivery to this district is timed on. A district this shop does
  # not serve never reaches here — {WireArguments.served_district} refuses it
  # first — so the fallback is the origin default and it is unreachable from the
  # wire.
  def zone_for(district)
    Time.find_zone!(DublinZones.zone_name_for(district) || DEFAULT_ZONE_NAME)
  end

  # "Now" at the delivery address — the reference point for past-slot filtering.
  def now(zone = default_zone)
    zone.now
  end

  # THE DAY A PUBLISHED EXAMPLE NAMES: tomorrow, on the ORIGIN's own clock — a
  # descriptor is one document for every district this shop delivers to, so it
  # addresses none of them.
  #
  # A descriptor's `example_params`/`example_row` say «copy this verbatim», and
  # a calendar literal there stops being true on a day nobody notices: a `date`
  # before today is REFUSED, so a published literal ages into a 400. Tomorrow is
  # the right answer rather than today because EVERY window
  # of a future day is still bookable — today's example would go empty at 18:00
  # Dublin — and because tomorrow is already what a blank `delivery_date` means
  # to both write verbs, so an assistant that copies the catalogue gets exactly
  # what omitting the argument would have given it.
  #
  # Read through a proc from the declaration, never called at class-body load —
  # see {Kiosk::Server::SchemaSlots}.
  def example_date
    now.to_date + 1
  end

  # Start-of-slot as a zoned Time at the DELIVERY ADDRESS, DST-correct.
  # slot_id is 1..COUNT. Its .iso8601 carries the real offset
  # (+01:00 in summer / +00:00 in winter), so an assistant reads an unambiguous
  # instant, and create_order books EXACTLY this instant.
  def slot_at(date, slot_id, zone = default_zone)
    hour = FIRST_HOUR + (slot_id.to_i - 1) * WINDOW_HOURS
    zone.local(date.year, date.month, date.day, hour, 0, 0)
  end

  # The window rendered for a human, IN THE ZONE IT NAMES — "08:00–10:00
  # (Europe/Dublin)". ONE writer for the whole demo, and every verb that speaks
  # this window goes through it: `delivery_slots` offers a window, `create_order`
  # books it, `reschedule_delivery` moves it and `my_orders` reads it back —
  # four verbs, one string about one window. Written four times they are four
  # answers that drift.
  #
  # It takes an INSTANT rather than a slot_id because `my_orders` has only the
  # stored instant, and it reads the hour off THIS zone rather than off the
  # value's own offset: ActiveRecord hands a `timestamptz` back as a
  # TimeWithZone in `Time.zone`, which is UTC here because this app sets no
  # `config.time_zone`, and the label must name the DELIVERY ADDRESS's.
  def label(time, zone = default_zone)
    hour = time.in_time_zone(zone).hour
    "#{hour.to_s.rjust(2, "0")}:00–#{(hour + WINDOW_HOURS).to_s.rjust(2, "0")}:00 (#{zone.name})"
  end

  # Has this (date, slot_id) window's START already passed, relative to `at`
  # (default: now)? A window that has already begun is no longer bookable as a
  # fresh delivery, so we filter on START (not end): at 11:00 the 08:00–10:00
  # AND the 10:00–12:00 windows are both gone; 12:00–14:00 stays.
  #
  # `at:` DEFAULTS TO A ZONE-FREE `now` ON PURPOSE, and it is not a shortcut:
  # this comparison is between INSTANTS, and «now» is ONE instant whichever
  # zone renders it. The zone-sensitive half is which instant «08:00 on this
  # date» IS, and that is {.slot_at}'s, which takes the delivery address's
  # zone. A caller that needs the DAY rather than the instant asks {.now} for
  # the zone it means.
  def past?(date, slot_id, zone = default_zone, at: now)
    slot_at(date, slot_id, zone) <= at
  end

  # The still-bookable slot_ids for a date at one address: every slot for a
  # FUTURE date; for TODAY only those whose start has not passed there. An empty
  # result for today means the last window has begun — the earliest bookable
  # slot is on a later date (correct: today is sold out).
  def bookable_ids(date, zone = default_zone, at: now)
    (1..COUNT).reject { |slot_id| past?(date, slot_id, zone, at: at) }
  end
end
