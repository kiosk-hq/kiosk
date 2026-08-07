# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for the DeliverySlots helper —
# the pure past-slot-filter + operator-locale-zone logic behind K-480. Run with:
#   bundle exec rake demo:slots_spec      (or: ruby spec/delivery_slots_spec.rb)
#
# It stubs "now in Dublin" to a fixed instant and asserts:
#   • at 11:00 Dublin, today's 08:00 and 10:00 windows are HIDDEN, 12:00+ stay;
#   • past?/bookable_ids are DST-correct (real Europe/Dublin zone, IST + GMT);
#   • a future date keeps all 6 slots; a fully-past today yields none.
# This is the DB-free test seam for the fix (getgrocery ships no rspec).

require "active_support"
require "active_support/core_ext/time"
require "date"

require_relative "../lib/delivery_slots"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# Freeze "now" to a specific Dublin instant for the duration of the block.
def at_dublin(iso)
  fixed = DeliverySlots.zone.parse(iso)
  DeliverySlots.define_singleton_method(:now) { fixed }
  yield fixed
ensure
  DeliverySlots.singleton_class.send(:remove_method, :now)
end

dublin = DeliverySlots.zone

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

if FAILURES.empty?
  puts "\nDeliverySlots K-480 spec: ALL PASS"
  exit 0
else
  puts "\nDeliverySlots K-480 spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
