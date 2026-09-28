# frozen_string_literal: true

# Standalone (no rails boot, no DB, no server) unit spec for the CALLER's clock:
# where this shop is allowed to learn it, and where it is not allowed to reach.
# Run with:
#   bundle exec rake check:clock_spec   (or: ruby spec/caller_clock_spec.rb)
#
# THE CLOCK IS STUBBED, which is what lets these properties be asserted at all.
# `travel_to` pins `Time.now`, so `zone.now` — everything this shop reads a day
# off — answers a known instant. Two consequences, and both are the reason the
# file is written this way:
#
#   * A pinned instant can be placed EXACTLY where the rule bites. The control
#     below needs two declared zones whose calendar DATES differ, and with the
#     clock pinned that is two hours of offset rather than twenty-five: at
#     22:30 UTC a caller in Bucharest is already on tomorrow while the shop in
#     Dublin is half an hour from it. Read off the wall clock the same pair is
#     only usable for two hours a day.
#   * Nothing waits for a date to roll over, so the answers are the same on
#     every run and a failure is a defect rather than the hour it ran at.
#
# THREE PROPERTIES, one per section:
#   1. §3.8.5's MUST NOT — the zone is DECLARED in `Kiosk-Timezone` and is read
#      from nowhere else: not the locale, not a geolocation hint, not the token,
#      not the TCP peer. All four are reachable here; over the wire the last two
#      are not, which is why this file holds the rule and the redteam battery's
#      `CallerZoneIsNotInferred` holds the two halves a client can present.
#   2. THE CONTROL — a declared zone MOVES the answer. Without it "the baits
#      changed nothing" would also be true of a shop that read no clock at all.
#   3. §3.8.9's second sentence — ONE rendering per row. The window rows this
#      shop publishes are a function of the delivery district and the day, so
#      they carry the district's clock and never the caller's.
#
# WATCHED FAIL: give {WireArguments.caller_day} the shop's zone in place of
# `from` (`start = zone.local(...)`) and section 2 goes red — the Bucharest
# caller's ended day is accepted as though it were the shop's. Have
# {Kiosk::Server::CallerTimezone.from_env} fall back to `env["HTTP_CF_IPCOUNTRY"]`
# and section 1 goes red on the bait that carries it.

require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require "active_support/testing/time_helpers"
require "date"
require "kiosk/operation_result"
require "kiosk/server/caller_timezone"

require_relative "../app/models/delivery_slots"
require_relative "../app/models/dublin_zones"
require_relative "../app/operations/operation_result"
require_relative "../app/operations/wire_arguments"

include ActiveSupport::Testing::TimeHelpers

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# 22:30 UTC on the 7th: 23:30 on the 7th in Dublin, 01:30 on the EIGHTH in
# Bucharest. One instant, two calendar days, two hours of offset between them.
PIN      = Time.utc(2026, 9, 7, 22, 30, 0)
NEXT_DAY = PIN + 86_400
THE_7TH  = Date.new(2026, 9, 7)

SHOP_ZONE        = DeliverySlots.default_zone          # the shop's, and D02's
CALLER_BUCHAREST = Time.find_zone!("Europe/Bucharest")  # UTC+3: already on the 8th
CALLER_LISBON    = Time.find_zone!("Europe/Lisbon")     # UTC+1: still on the 7th

IN_ZONE_ADDRESS = "42 Camden Street, Dublin 2"

puts "  pinned instant: #{PIN.iso8601} — shop #{SHOP_ZONE.name} #{PIN.in_time_zone(SHOP_ZONE).iso8601}, " \
     "caller #{CALLER_BUCHAREST.name} #{PIN.in_time_zone(CALLER_BUCHAREST).iso8601}"

# The earliest day this shop can serve, computed the way the handler computes it.
def soonest_day
  day = DeliverySlots.now(SHOP_ZONE).to_date
  DeliverySlots.bookable_ids(day, SHOP_ZONE).empty? ? day + 1 : day
end

# The day a `date` argument resolves to, or the refusal it earns.
def resolve(date, caller_zone:)
  WireArguments.caller_day(date, zone: SHOP_ZONE, caller_zone: caller_zone, soonest: soonest_day)
end

# ── 1. §3.8.5's MUST NOT — DECLARED, never inferred ───────────────────────────
#
# «An operator MUST NOT source the caller's zone from anywhere else — not from
# the access token, not from Accept-Language, not from IP geolocation, not from
# the TCP peer.» That is an ABSENCE, and the way to hold one is to present every
# forbidden source at once and require the answer to be the one a request that
# presented none of them gets.
#
# The env below carries all four, every one of them pointing at Bucharest — the
# zone section 2 proves would MOVE this answer. The token and the TCP peer are
# in it because this is the seam where they are reachable: a client cannot forge
# `REMOTE_ADDR`, and nothing in this engine's claim set carries a zone, so over
# the wire those two halves can only be argued.
BAITED = {
  "HTTP_ACCEPT_LANGUAGE" => "ro-RO, ro;q=0.9",
  "HTTP_X_FORWARDED_FOR" => "5.2.0.1",
  "HTTP_CF_IPCOUNTRY"    => "RO",
  "HTTP_TRUE_CLIENT_IP"  => "5.2.0.1",
  "REMOTE_ADDR"          => "5.2.0.1",
  "HTTP_AUTHORIZATION"   => "Bearer #{["{}", '{"tz":"Europe/Bucharest"}', ""].join(".")}",
}.freeze

puts "\n── the caller's zone is DECLARED, and read from nothing else ──"
travel_to(PIN) do
  assert(Kiosk::Server::CallerTimezone.from_env({}).nil?,
         "a request declaring nothing declares nothing")
  assert(Kiosk::Server::CallerTimezone.from_env(BAITED).nil?,
         "…and so does one carrying a locale, three geolocation hints, a zone-bearing token " \
         "and a Bucharest TCP peer: #{Kiosk::Server::CallerTimezone.from_env(BAITED).inspect}")

  # Each source ALONE, so a pass cannot come from one of them being ignored
  # while another is read.
  BAITED.each_key do |key|
    assert(Kiosk::Server::CallerTimezone.from_env(key => BAITED[key]).nil?,
           "…#{key} on its own sources no zone either")
  end

  # AND THE WHOLE CHAIN, not the header reader alone: what the baits must not
  # move is the DAY this shop answers with.
  bare   = resolve(THE_7TH, caller_zone: Kiosk::Server::CallerTimezone.from_env({}))
  baited = resolve(THE_7TH, caller_zone: Kiosk::Server::CallerTimezone.from_env(BAITED))
  assert(baited == bare && bare[1].nil? && bare[0] == Date.new(2026, 9, 8),
         "the day the shop answers is identical bare and baited (#{bare[0]}), " \
         "and it is the shop's soonest — the caller's own 7th has not ended")
end

# ── 2. THE CONTROL — a DECLARED zone MOVES the answer ────────────────────────
#
# ONE argument, TWO declared zones, TWO answers: `2026-09-07` is a day a Lisbon
# caller is still inside and a day a Bucharest caller left half an hour ago. A
# shop that read no clock, or that read one and then judged the day on its own,
# could not answer them differently — so section 1's "the baits changed nothing"
# is not a shop that changes nothing.
puts "\n── a DECLARED zone moves the answer: one day, two calendars ──"
travel_to(PIN) do
  still_in = resolve(THE_7TH, caller_zone: CALLER_LISBON)
  assert(still_in[1].nil? && still_in[0] == Date.new(2026, 9, 8),
         "declared #{CALLER_LISBON.name} (00:30 short of midnight): answered on the shop's " \
         "#{still_in[0]}, which the row then carries")

  ended = resolve(THE_7TH, caller_zone: CALLER_BUCHAREST)
  refusal = ended[1]
  assert(ended[0].nil? && refusal.is_a?(OperationResult) && !refusal.ok? &&
         refusal.code == "bad_request",
         "declared #{CALLER_BUCHAREST.name} (01:30 into the 8th): the same day is a typed 400, " \
         "got #{refusal.inspect[0, 70]}")
  if refusal.is_a?(OperationResult)
    assert(refusal.message.include?("2026-09-07") && refusal.message.include?(CALLER_BUCHAREST.name) &&
           refusal.message.include?("2026-09-08"),
           "…naming the day, the calendar it was judged on and the earliest day to ask for: " \
           "#{refusal.message}")
    assert(!refusal.message.include?(SHOP_ZONE.name),
           "…and NOT the shop's clock, which is not the one that decided")
  end

  # An unreadable declaration is refused BY NAME rather than fallen back on, so
  # the header is demonstrably READ and not merely accepted.
  offset = begin
    Kiosk::Server::CallerTimezone.from_value("+03:00")
    nil
  rescue Kiosk::Server::Errors::BadRequest => e
    e
  end
  assert(!offset.nil? && offset.message.include?(Kiosk::Server::CallerTimezone::HEADER),
         "a UTC offset is refused by name rather than silently replaced: #{offset&.message}")
end

# ── 3. §3.8.9's second sentence — ONE rendering per row ─────────────────────
#
# «An operator publishes ONE rendering per row and not two — a second wall clock
# in the caller's zone is a field pair that can disagree.» A window is rendered
# at the delivery address, so its row is a function of (district, day) and the
# caller's zone is not one of the inputs. Two things are asserted, and the
# second is what makes the first falsifiable:
#
#   the rows for one future day are byte-identical at two pinned instants whose
#   own DATES differ, and name the district's zone and neither caller's;
#
#   and the writers those rows are built from DO move when they are handed
#   another zone — so a caller zone that reached one would be visible.
RENDERING = %w[delivery_slot_id date slot_at label timezone district].freeze

def rows_for(day)
  district, = WireArguments.served_district(IN_ZONE_ADDRESS)
  zone      = DeliverySlots.zone_for(district)
  DeliverySlots.bookable_ids(day, zone).map do |slot_id|
    at = DeliverySlots.slot_at(day, slot_id, zone)
    { "delivery_slot_id" => slot_id, "date" => day.iso8601, "slot_at" => at.iso8601,
      "label" => DeliverySlots.label(at, zone), "timezone" => zone.name,
      "district" => district }
  end
end

puts "\n── one rendering per row, at the district's clock ──"
future = Date.new(2026, 9, 20)
at_pin = travel_to(PIN) { rows_for(future) }
at_next = travel_to(NEXT_DAY) { rows_for(future) }

assert(at_pin.any? && at_pin == at_next,
       "#{at_pin.size} window(s) for #{future} render identically at #{PIN.to_date} and at " \
       "#{NEXT_DAY.to_date} — the day's rendering is the district's, not the reader's moment")
assert(at_pin.any? && at_pin.all? { |r| r.keys.sort == RENDERING.sort },
       "every row carries exactly one rendering and names its zone: #{RENDERING.join(", ")}")
assert(at_pin.any? && at_pin.all? { |r| r["timezone"] == SHOP_ZONE.name && r["label"].include?(SHOP_ZONE.name) },
       "…the zone is the DISTRICT's and the label says it out loud: #{at_pin.first&.fetch("label", nil)}")
bytes = at_pin.to_s
assert(!bytes.include?(CALLER_BUCHAREST.name) && !bytes.include?(CALLER_LISBON.name),
       "…and no caller's zone appears anywhere in the answer's bytes")

moved = travel_to(PIN) { DeliverySlots.label(DeliverySlots.slot_at(future, 1, SHOP_ZONE), CALLER_BUCHAREST) }
assert(!at_pin.empty? && moved != at_pin.first["label"],
       "handed another zone the SAME writer renders differently (#{moved}) — so a caller " \
       "zone reaching it would be visible, and the rows above not moving is a fact")

puts
if FAILURES.empty?
  puts "  caller-clock spec: all assertions passed (TZ=#{ENV["TZ"] || "unset"})"
  exit 0
else
  puts "  caller-clock spec: #{FAILURES.length} FAILED (TZ=#{ENV["TZ"] || "unset"})"
  FAILURES.each { |f| puts "    - #{f}" }
  exit 1
end
