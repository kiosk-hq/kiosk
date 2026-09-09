# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for the DeliverySlots helper —
# the pure past-slot-filter + delivery-address-zone logic. Run with:
#   bundle exec rake demo:slots_spec      (or: ruby spec/delivery_slots_spec.rb)
#
# It stubs "now at the address" to a fixed instant and asserts:
#   • at 11:00 Dublin, today's 08:00 and 10:00 windows are HIDDEN, 12:00+ stay;
#   • past?/bookable_ids are DST-correct (real Europe/Dublin zone, IST + GMT);
#   • a future date keeps all 6 slots; a fully-past today yields none;
#   • every helper follows the ZONE IT IS HANDED and invents none — a delivery
#     happens at the door, so the clock is the ADDRESS's district's and not one
#     constant for this shop.
# This is the DB-free test seam for the fix (getgrocery ships no rspec).

require "active_support"
require "active_support/core_ext/time"
require "date"

require_relative "../app/models/dublin_zones"
require_relative "../app/models/delivery_slots"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# Freeze "now" to a specific Dublin instant for the duration of the block. The
# stub takes the zone argument and IGNORES it: this helper freezes an instant,
# and what the surrounding assertions vary is the zone each call is HANDED.
def at_dublin(iso)
  fixed = DeliverySlots.default_zone.parse(iso)
  DeliverySlots.define_singleton_method(:now) { |_zone = nil| fixed }
  yield fixed
ensure
  DeliverySlots.singleton_class.send(:remove_method, :now)
end

dublin = DeliverySlots.default_zone

# ── Summer (IST, UTC+1): 2026-08-07 11:00 Dublin ─────────────────────────────
summer_date = Date.new(2026, 8, 7)
at_dublin("2026-08-07T11:00:00") do
  # slot_at carries the +01:00 summer offset, DST-correct.
  s1 = DeliverySlots.slot_at(summer_date, 1)
  assert(s1.utc_offset == 3600, "summer slot_at offset is +01:00 (IST): #{s1.iso8601}")

  # 08:00 and 10:00 windows have started → hidden; 12:00/14:00/16:00/18:00 stay.
  ids = DeliverySlots.bookable_ids(summer_date)
  assert(ids == [3, 4, 5, 6], "at 11:00 Dublin (summer) bookable today = [3,4,5,6] (08:00 & 10:00 dropped), got #{ids.inspect}")
  assert(DeliverySlots.past?(summer_date, 1),  "slot 1 (08:00) is past at 11:00")
  assert(DeliverySlots.past?(summer_date, 2),  "slot 2 (10:00) is past at 11:00")
  assert(!DeliverySlots.past?(summer_date, 3), "slot 3 (12:00) is NOT past at 11:00")

  # A FUTURE date keeps all 6 slots (no filtering).
  future = DeliverySlots.bookable_ids(summer_date + 1)
  assert(future == [1, 2, 3, 4, 5, 6], "a future date keeps all 6 slots, got #{future.inspect}")
end

# ── Fully-past today: 2026-08-07 23:00 Dublin → today yields NO slots ─────────
at_dublin("2026-08-07T23:00:00") do
  ids = DeliverySlots.bookable_ids(summer_date)
  assert(ids.empty?, "late at night, today has NO bookable slots (all windows started), got #{ids.inspect}")
end

# ── Early morning: 2026-08-07 06:00 Dublin → all of today still bookable ──────
at_dublin("2026-08-07T06:00:00") do
  ids = DeliverySlots.bookable_ids(summer_date)
  assert(ids == [1, 2, 3, 4, 5, 6], "before 08:00 all of today is bookable, got #{ids.inspect}")
end

# ── Winter (GMT, UTC+0): 2026-01-15 → slot_at offset is +00:00, DST-safe ──────
winter_date = Date.new(2026, 1, 15)
w1 = DeliverySlots.slot_at(winter_date, 1)
assert(w1.utc_offset.zero?, "winter slot_at offset is +00:00 (GMT), not a hardcoded +1: #{w1.iso8601}")

# ── THE CLOCK COMES OFF THE DELIVERY ADDRESS ─────────────────────────────────
#
# A delivery happens at the door, so the zone a window is written in belongs to
# the district the address routed to. Every district this shop serves is in
# Dublin today, so no answer moves — what is provable here is that the SOURCE is
# the district and that every helper follows the zone it is handed rather than
# reaching for a constant. A shop that opened a depot elsewhere would add one
# row to {DublinZones::ZONES}.
puts "\n── the zone is the delivery district's, and every helper honours it ──"
assert(DeliverySlots::DEFAULT_ZONE_NAME == "Europe/Dublin",
       "the ORIGIN default is #{DeliverySlots::DEFAULT_ZONE_NAME} — what dates a published example, " \
       "NOT what a request is answered on")
assert(DublinZones::ZONES.keys.sort == DublinZones::SERVED.sort,
       "every served district declares a clock, and no district declares one this shop does not " \
       "serve — otherwise a deliverable address would have no zone, or a zone would name nothing")
assert(DublinZones::ZONES.values.uniq == ["Europe/Dublin"],
       "…and today they are all Dublin, so no response byte moves: #{DublinZones::ZONES.values.uniq.inspect}")
assert(DeliverySlots.zone_for("D02").name == "Europe/Dublin",
       "zone_for(\"D02\") reads that district's declared clock")

# Handed a DIFFERENT zone, every helper answers on it. This is what makes the
# source per-address rather than per-origin: the functions carry no clock of
# their own.
TOKYO = Time.find_zone!("Asia/Tokyo")
d = Date.new(2026, 8, 7)
assert(DeliverySlots.slot_at(d, 1, TOKYO).utc_offset == 9 * 3600,
       "slot_at honours the zone it is given (+09:00 in Tokyo), got " \
       "#{DeliverySlots.slot_at(d, 1, TOKYO).utc_offset / 3600}")
assert(DeliverySlots.slot_at(d, 1, TOKYO).to_i != DeliverySlots.slot_at(d, 1, dublin).to_i,
       "…so an 08:00 window is a DIFFERENT instant at two addresses, which is the whole point")
assert(DeliverySlots.label(DeliverySlots.slot_at(d, 1, TOKYO), TOKYO) == "08:00–10:00 (Asia/Tokyo)",
       "the label NAMES the zone it was handed, got " \
       "#{DeliverySlots.label(DeliverySlots.slot_at(d, 1, TOKYO), TOKYO)}")
assert(DeliverySlots.label(DeliverySlots.slot_at(d, 1, dublin)) == "08:00–10:00 (Europe/Dublin)",
       "…and falls back to the origin default when nobody named one")
at_dublin("2026-08-07T11:00:00") do
  # 11:00 in Dublin is 19:00 in Tokyo, so every one of that day's windows has
  # begun there while four are still open in Dublin — the same call, the same
  # day, two addresses, two answers, and neither is wrong.
  assert(DeliverySlots.bookable_ids(d, dublin) == [3, 4, 5, 6],
         "in Dublin four windows are still open, got #{DeliverySlots.bookable_ids(d, dublin).inspect}")
  assert(DeliverySlots.bookable_ids(d, TOKYO).empty?,
         "at the same instant a Tokyo address has none left, got " \
         "#{DeliverySlots.bookable_ids(d, TOKYO).inspect} — one origin-wide clock could not say both")
end

if FAILURES.empty?
  puts "\nDeliverySlots spec: ALL PASS"
  exit 0
else
  puts "\nDeliverySlots spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
