# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for `app/operations/wire_arguments.rb`
# — the module that decides whether a hostile wire argument becomes a typed 400
# or a booked order. Run with:
#   bundle exec rake demo:wire_args_spec   (or: ruby spec/wire_arguments_spec.rb)
#
# WHY IT IS DB-FREE, and why that is the whole point. Every guard in here is a
# PURE FUNCTION over its argument: `whole_number` reads no clock, `items` opens
# no connection, `order_id` is a regexp. Without this file the only executable
# coverage of any of them would be `demo:redteam`, which needs a booted origin,
# a seeded database and a live Equihash toll — so proving a table about ten
# literal values would cost all three, and would mean MUTATING a published
# `input_schema`. The two cheaper siblings on this demo (`DeliverySlots` →
# demo:slots_spec, `Kiosk::UuidCheck` → demo:cashier_spec) already have this seam; the
# module that actually stands between the wire and the order needs it most.
#
# WHAT IS ASSERTED. Not "something was refused" — the TYPE and the SHAPE of each
# refusal:
#   • every refusal is an {OperationResult} with `code == "bad_request"` whose
#     `status` resolves through getgrocery's own STATUSES map to `:bad_request`,
#     so a code this demo never mapped would raise a KeyError here rather than
#     at the wire;
#   • no hostile shape RAISES. A bare `.to_i` (or `||`, or `.map`) answers some
#     shapes with a 500 and mis-answers others, and a guard that raises is not
#     a guard;
#   • the SHAPE refusal and the RANGE refusal are DIFFERENT sentences —
#     `1.5` is not "out of range", and a caller told the wrong one debugs the
#     wrong thing;
#   • the accepted shapes are exactly the published `input_schema`'s and nothing
#     looser (JSON Schema's `integer` is numeric, so `2.0` IS one) and
#     nothing stricter.
#
# CART KEYS ARE SYMBOLS here because that is what {CreateOrderOperation} hands
# over: the controller unwraps ActionController::Parameters before gate 1, so
# `items` reaches this module as plain Ruby.

require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require "date"
require "securerandom"
require "kiosk/uuid_check"
require "kiosk/operation_result"

require_relative "../app/models/delivery_slots"
require_relative "../app/models/dublin_zones"
require_relative "../app/operations/operation_result"
require_relative "../app/operations/wire_arguments"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# Call a guard and never let it raise past this line: a raise IS the defect this
# module exists to prevent, so it is recorded as a failed assertion rather than
# ending the run.
def guard(label)
  yield
rescue StandardError, NoMethodError => e
  FAILURES << "#{label} RAISED #{e.class}: #{e.message}"
  puts "  FAIL  #{label} RAISED #{e.class}: #{e.message}"
  nil
end

# Every refusal in this module is the same TYPE and the same wire shape. Asserted
# once per refusal rather than described once in prose.
def assert_typed_400(result, label)
  unless result.is_a?(OperationResult)
    return assert(false, "#{label} → an OperationResult, got #{result.class}")
  end

  ok = !result.ok? && result.code == "bad_request" && result.status == :bad_request
  assert(ok, "#{label} → typed 400 (#{result.code.inspect}/#{result.status.inspect}): #{result.message}")
end

# The `[value, refusal]` pair both halves of this module answer in.
def refusal_of(pair) = pair.is_a?(Array) ? pair[1] : pair
def value_of(pair)   = pair.is_a?(Array) ? pair[0] : nil

# Freeze "now" to a fixed Dublin instant, the way spec/delivery_slots_spec.rb
# does — {WireArguments} reads the ORIGIN's clock and never Date.today.
def at_dublin(iso)
  fixed = DeliverySlots.zone.parse(iso)
  DeliverySlots.define_singleton_method(:now) { fixed }
  yield fixed
ensure
  DeliverySlots.singleton_class.send(:remove_method, :now)
end

MAX = WireArguments::MAX_INT4

# ── 1. whole_number/1 — JSON Schema's `integer`, in Ruby ─────────────────────
#
# The two arguments in front of it (`qty`, `delivery_slot_id`) are declared
# `{type: "integer"}`, and draft 2020-12 defines that NUMERICALLY —
# so `2.0` is a valid integer and a bare `is_a?(Integer)` would refuse a call the
# published schema allows. Everything else JSON can carry is not a number at all.
puts "\n── whole_number: the schema's `integer` and nothing looser ──"
[
  # [raw, expected]
  [0,                     0],
  [1,                     1],
  [-1,                    -1],
  [2,                     2],
  [MAX,                   MAX],
  [MAX + 1,               MAX + 1],   # RANGE is the caller's question, not this one's
  [2**64,                 2**64],
  [2.0,                   2],         # a JSON `2.0` IS an integer (json_schemer agrees)
  [-3.0,                  -3],
  [1e18,                  10**18],
  [1.5,                   nil],
  [-0.5,                  nil],
  [0.1,                   nil],
  [Float::INFINITY,       nil],       # not finite → not a quantity
  [-Float::INFINITY,      nil],
  [Float::NAN,            nil],
  ["1",                   nil],       # a STRING is not a number here, deliberately
  ["1.5",                 nil],
  ["01",                  nil],
  ["0x10",                nil],
  ["",                    nil],
  ["abc",                 nil],
  [nil,                   nil],
  [true,                  nil],
  [false,                 nil],       # `||` reads this as ABSENT, so it may not be used here
  [[],                    nil],
  [[1],                   nil],
  [{},                    nil],
  [{ "a" => 1 },          nil],
  [:two,                  nil],
].each do |raw, want|
  got = guard("whole_number(#{raw.inspect})") { WireArguments.whole_number(raw) }
  assert(got == want && got.class == want.class,
         "whole_number(#{raw.inspect}) → #{want.inspect} (#{want.class}), got #{got.inspect} (#{got.class})")
end

# ── 2. delivery_slot_id/1 — SHAPE and RANGE are two answers ──────────────────
puts "\n── delivery_slot_id: shape first, then range ──"
(1..DeliverySlots::COUNT).each do |slot|
  pair = guard("delivery_slot_id(#{slot})") { WireArguments.delivery_slot_id(slot) }
  assert(refusal_of(pair).nil? && value_of(pair).eql?(slot),
         "delivery_slot_id(#{slot}) → #{slot} with no refusal, got #{pair.inspect}")
end

pair = guard("delivery_slot_id(2.0)") { WireArguments.delivery_slot_id(2.0) }
assert(refusal_of(pair).nil? && value_of(pair).eql?(2),
       "delivery_slot_id(2.0) → the Integer 2 (the schema's `integer` is numeric), got #{pair.inspect}")

# OUT OF RANGE — well-formed, outside 1..6. The RANGE sentence.
[0, 7, -1, MAX + 1, 100.0].each do |raw|
  refusal = refusal_of(guard("delivery_slot_id(#{raw.inspect})") { WireArguments.delivery_slot_id(raw) })
  assert_typed_400(refusal, "delivery_slot_id(#{raw.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "delivery_slot_id must be 1–#{DeliverySlots::COUNT}",
         "  … the RANGE sentence, not the shape one: #{refusal.message.inspect}")
end

# WRONG SHAPE — not a whole number at all. The SHAPE sentence, echoing the value.
# `1.5` is the one to watch: `raw.to_s.to_i` would make it slot 1 and BOOK it,
# inside the declared range, from the layer that claims to be stricter than the
# schema in front of it.
[1.5, "1", "abc", "", nil, true, false, [], [1], {}, { "a" => 1 }].each do |raw|
  refusal = refusal_of(guard("delivery_slot_id(#{raw.inspect})") { WireArguments.delivery_slot_id(raw) })
  assert_typed_400(refusal, "delivery_slot_id(#{raw.inspect})")
  next unless refusal.is_a?(OperationResult)

  want = "delivery_slot_id must be a whole number 1–#{DeliverySlots::COUNT} — got #{raw.inspect}"
  assert(refusal.message == want,
         "  … the SHAPE sentence echoing the value: #{refusal.message.inspect}")
end

# ── 3. items/1 — the cart, and `qty` as strict as the schema ──────────────────
puts "\n── items: the cart guard, and both ends of qty's declared range ──"

# NOT AN ARRAY. The class is named so the caller can see what it sent.
{
  "x"                => "String",
  1                  => "Integer",
  ({ sku: "a" })     => "Hash",
  true               => "TrueClass",
}.each do |raw, klass|
  refusal = refusal_of(guard("items(#{raw.inspect})") { WireArguments.items(raw) })
  assert_typed_400(refusal, "items(#{raw.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "items must be an array of {sku, qty} objects — got #{klass}",
         "  … names the class it got: #{refusal.message.inspect}")
end

refusal = refusal_of(guard("items(nil)") { WireArguments.items(nil) })
assert_typed_400(refusal, "items(nil)")
assert(refusal.is_a?(OperationResult) &&
       refusal.message == "items must be an array of {sku, qty} objects — got nothing",
       "  … an ABSENT cart reads as \"nothing\", not \"NilClass\": #{refusal&.message.inspect}")

refusal = refusal_of(guard("items([])") { WireArguments.items([]) })
assert_typed_400(refusal, "items([])")
assert(refusal.is_a?(OperationResult) && refusal.message == "items must be a non-empty array",
       "  … an EMPTY cart is its own sentence: #{refusal&.message.inspect}")

# AN ELEMENT THAT IS NOT AN OBJECT — `["bread"]` used to reach `it[:sku]`.
["bread", 2, nil, [], true].each do |bad|
  refusal = refusal_of(guard("items([#{bad.inspect}])") { WireArguments.items([bad]) })
  assert_typed_400(refusal, "items([#{bad.inspect}])")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message.start_with?("each item must be a {sku, qty} object — got #{bad.class}") &&
         refusal.message.include?("sourdough-bread"),
         "  … names the class AND shows a well-formed item: #{refusal.message.inspect}")
end

# A MISSING sku.
[{ qty: 1 }, { sku: "", qty: 1 }, { sku: nil, qty: 1 }, { "sku" => "bread", qty: 1 }].each do |item|
  refusal = refusal_of(guard("items([#{item.inspect}])") { WireArguments.items([item]) })
  assert_typed_400(refusal, "items([#{item.inspect}])")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "each item needs a sku", "  … #{refusal.message.inspect}")
end

# qty, WRONG SHAPE. `false` and `1.5` are the two to watch:
# `(item[:qty] || 1).to_s.to_i` reads `false` as ABSENT and defaults it to 1,
# and turns `1.5` into 1. An ABSENT qty is refused too — `input_schema` makes
# it `required`, so a default here would be a second, weaker contract nobody
# published.
[nil, false, true, 1.5, "1", "2", "abc", [], {}, [1], Float::NAN].each do |bad|
  item    = bad.nil? ? { sku: "bread" } : { sku: "bread", qty: bad }
  refusal = refusal_of(guard("items([#{item.inspect}])") { WireArguments.items([item]) })
  assert_typed_400(refusal, "items(qty: #{bad.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "qty must be a whole number >= 1 — got #{bad.inspect}",
         "  … the SHAPE sentence echoing the value: #{refusal.message.inspect}")
end

# qty, OUT OF RANGE at the bottom — a different sentence from the shape one.
[0, -1, -MAX, 0.0, -2.0].each do |bad|
  refusal = refusal_of(guard("items(qty: #{bad.inspect})") { WireArguments.items([{ sku: "bread", qty: bad }]) })
  assert_typed_400(refusal, "items(qty: #{bad.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "qty must be >= 1", "  … the RANGE floor: #{refusal.message.inspect}")
end

# qty, OUT OF RANGE at the top — `order_items.qty` is a 4-byte integer,
# and the bound is the COLUMN's, not a policy about basket size.
[MAX + 1, 2**40, (MAX + 1).to_f].each do |bad|
  refusal = refusal_of(guard("items(qty: #{bad.inspect})") { WireArguments.items([{ sku: "bread", qty: bad }]) })
  assert_typed_400(refusal, "items(qty: #{bad.inspect})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message == "qty must be <= #{MAX} — got #{bad.to_i}",
         "  … the RANGE ceiling: #{refusal.message.inspect}")
end

# THE ACCEPTED CART, and what it normalises to.
pair = guard("items(happy)") do
  WireArguments.items([{ sku: "sourdough-bread", qty: 2 }, { sku: :milk, qty: 3.0 }, { sku: "eggs", qty: MAX }])
end
assert(refusal_of(pair).nil?, "a well-formed cart is not refused, got #{refusal_of(pair)&.message.inspect}")
assert(value_of(pair) == [{ sku: "sourdough-bread", qty: 2 }, { sku: "milk", qty: 3 }, { sku: "eggs", qty: MAX }],
       "  … normalised to String skus and Integer qtys: #{value_of(pair).inspect}")
assert(value_of(pair)&.all? { |i| i[:qty].is_a?(Integer) },
       "  … every qty is an Integer, so `price_cents * qty` cannot be a Float")

# THE FIRST bad item decides, and the answer names THAT item.
refusal = refusal_of(guard("items(good, bad)") do
  WireArguments.items([{ sku: "bread", qty: 1 }, { sku: "milk", qty: 0 }, { sku: "eggs", qty: 1.5 }])
end)
assert(refusal.is_a?(OperationResult) && refusal.message == "qty must be >= 1",
       "the FIRST bad item decides — a later 1.5 does not change the answer: #{refusal&.message.inspect}")

# ── 4. priceable_total/1 — the half no per-item bound can express ────────────
#
# The cart's TOTAL is `price_cents * qty` summed over the OPERATOR's catalogue,
# so no JSON Schema keyword can bound it: at an 89-cent row it takes 24_129_030
# units — a legal `order_items.qty` — to pass `orders.total_cents`.
puts "\n── priceable_total: the ceiling `input_schema` cannot express ──"
[0, 1, MAX].each do |total|
  assert(guard("priceable_total(#{total})") { WireArguments.priceable_total(total) }.nil?,
         "priceable_total(#{total}) → nil (the cart can be totalled)")
end
[MAX + 1, 2**40].each do |total|
  refusal = guard("priceable_total(#{total})") { WireArguments.priceable_total(total) }
  assert_typed_400(refusal, "priceable_total(#{total})")
  next unless refusal.is_a?(OperationResult)

  assert(refusal.message.include?(total.to_s) && refusal.message.include?(MAX.to_s),
         "  … names the total AND the ceiling: #{refusal.message}")
  assert(refusal.hint.to_s.include?("split the cart"), "  … carries a recoverable hint: #{refusal.hint}")
end

# ── 5. order_id/1 — the uuid shape guard, and its two tails ──────────────────
#
# ActiveRecord does not refuse junk, it CASTS it: `where(id: junk)` becomes NULL
# and matches no row, so without this a typo comes back as an OWNERSHIP refusal
# (403) rather than a shape one (400).
puts "\n── order_id: the shape check that keeps a typo from reading as a 403 ──"
20.times do
  id   = SecureRandom.uuid
  pair = guard("order_id(#{id})") { WireArguments.order_id(id, hint: WireArguments::HINT_ORDER_ID_MOVE) }
  assert(refusal_of(pair).nil? && value_of(pair) == id,
         "order_id accepts a SecureRandom.uuid verbatim (#{id})")
end

pair = guard("order_id(upcase)") do
  WireArguments.order_id("3F0C1A2E-4B5D-6E7F-8A9B-0C1D2E3F4A5B", hint: WireArguments::HINT_ORDER_ID_MOVE)
end
assert(refusal_of(pair).nil?, "order_id accepts an UPPER-CASE uuid (Postgres does)")

[
  "not-a-uuid",
  "'; DROP TABLE orders; --",
  "12345",
  "3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5",  # one hex digit short
  "3f0c1a2e4b5d6e7f8a9b0c1d2e3f4a5b",     # un-hyphenated: Postgres-legal, not canonical
  " 3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5b",
  nil,
  12_345,
  true,
  [],
  { "a" => 1 },
].each do |bad|
  [WireArguments::HINT_ORDER_ID_REPLACE, WireArguments::HINT_ORDER_ID_MOVE].each do |hint|
    pair    = guard("order_id(#{bad.inspect})") { WireArguments.order_id(bad, hint: hint) }
    refusal = refusal_of(pair)
    assert_typed_400(refusal, "order_id(#{bad.inspect})")
    next unless refusal.is_a?(OperationResult)

    assert(value_of(pair).nil?, "  … and yields NO value alongside the refusal")
    assert(refusal.message == "order_id #{bad.to_s.inspect} is not a uuid — #{hint}",
           "  … echoes the value and carries the CALLER's tail: #{refusal.message.inspect}")

    leaks = ["::uuid", "PG::", "ActiveRecord", "22P02", "SELECT", "UPDATE", "invalid input syntax"]
            .select { |needle| refusal.message.include?(needle) }
    assert(leaks.empty?, "  … leaks no SQL/PG internals (found #{leaks.inspect})")
  end
end

assert(WireArguments::HINT_ORDER_ID_REPLACE != WireArguments::HINT_ORDER_ID_MOVE,
       "the two tails are different sentences — create_order may still REPLACE, " \
       "reschedule_delivery needs one that is already paid for")

# ── 6. delivery_date/3 — the day, the default, and ONE clock ─────────────────
#
# `Date.parse` and NOT `Date.iso8601`, deliberately: what it loosely accepts is
# published behaviour on this verb pair. The clock is the ORIGIN's — around
# midnight a server-zone `Date.today` would let `create_order` accept a day
# `delivery_slots` refuses.
puts "\n── delivery_date: the default, the loose forms, the past, and the clock ──"
at_dublin("2026-08-07T11:00:00") do
  today    = DeliverySlots.now.to_date
  default  = today + 1
  past_msg = ->(d) { "delivery_date is in the past: #{d} — choose a current/future delivery slot" }
  call     = ->(raw) { WireArguments.delivery_date(raw, default: default, past_message: past_msg) }

  [nil, "", "   ", false].each do |blank|
    pair = guard("delivery_date(#{blank.inspect})") { call.(blank) }
    assert(refusal_of(pair).nil? && value_of(pair) == default,
           "a blank delivery_date (#{blank.inspect}) falls back to the caller's default (#{default}), " \
           "got #{pair.inspect}")
  end

  # TODAY is accepted — the boundary is the DAY, and it is read off DeliverySlots.now.
  pair = guard("delivery_date(today)") { call.(today.iso8601) }
  assert(refusal_of(pair).nil? && value_of(pair) == today,
         "TODAY in Dublin (#{today}) is accepted — the floor is the day, not the window")

  pair = guard("delivery_date(future)") { call.((today + 30).iso8601) }
  assert(refusal_of(pair).nil? && value_of(pair) == today + 30, "a future ISO date is parsed to a Date")

  # The LOOSE forms Date.parse accepts, which are published behaviour here.
  [["#{today.year}-#{format('%02d', today.month)}-#{format('%02d', today.day)}", today],
   [[(today + 2).iso8601], today + 2],
   [(today + 3).strftime("%Y%m%d"), today + 3]].each do |raw, want|
    pair = guard("delivery_date(#{raw.inspect})") { call.(raw) }
    assert(refusal_of(pair).nil? && value_of(pair) == want,
           "Date.parse's loose form #{raw.inspect} → #{want} (published behaviour, not an oversight)")
  end

  # ── WHAT THE PARSER REALLY ACCEPTS, WRITTEN DOWN ──────────────────────────
  #
  # The three forms above were the whole of this demo's record of its own
  # looseness, and the parser takes a good deal more. The rest is asserted here
  # — not because any of it is desirable, but because a record NARROWER than
  # the behaviour is what let the clock bug below live unnoticed. Whether the
  # looseness should be narrowed is a separate and still-open question; this
  # block only states where it stands. Every date the origin is frozen at here
  # is Friday 7 August 2026, so a completed value in the same month reads as
  # PAST — and the past refusal names the date it parsed, which is what makes
  # these assertions about the PARSE rather than about the refusal.

  # SLASH FORM IS DAY-FIRST, AND SILENTLY AMBIGUOUS. `09/01/2026` is the NINTH
  # OF JANUARY. An assistant that meant the first of September gets a date seven
  # months away — here a refusal, and on a future value simply the wrong day.
  refusal = refusal_of(guard('delivery_date("09/01/2026")') { call.("09/01/2026") })
  assert(refusal.is_a?(OperationResult) && refusal.message == past_msg.call(Date.new(2026, 1, 9)),
         "the slash form is DAY-first: \"09/01/2026\" parses as 9 January 2026, not 1 September — " \
         "#{refusal.is_a?(OperationResult) ? refusal.message.inspect : refusal.inspect}")

  pair = guard('delivery_date("12/09/2026")') { call.("12/09/2026") }
  assert(refusal_of(pair).nil? && value_of(pair) == Date.new(2026, 9, 12),
         "… and it is ACCEPTED rather than refused — \"12/09/2026\" books 12 September 2026")

  # PARTIAL VALUES. A month, an ordinal day or an ISO week with nothing else is
  # completed from TODAY — and today is the ORIGIN's, which is the fix this
  # block's ledger row is about.
  [["sep",   Date.new(2026, 9, 1),  "a bare month name starts on the 1st"],
   ["250",   Date.new(2026, 9, 7),  "a bare ordinal day is that day of the origin's year"],
   ["W36-2", Date.new(2026, 9, 1),  "an ISO week-and-weekday resolves inside the origin's year"]].each do |raw, want, why|
    pair = guard("delivery_date(#{raw.inspect})") { call.(raw) }
    assert(refusal_of(pair).nil? && value_of(pair) == want,
           "partial value #{raw.inspect} → #{want} — #{why}")
  end

  [["Tue", Date.new(2026, 8, 4), "a bare weekday is the one in the origin's current week, Sunday-first"],
   ["1st", Date.new(2026, 8, 1), "a bare day-of-month is that day of the origin's current month"]].each do |raw, want, why|
    refusal = refusal_of(guard("delivery_date(#{raw.inspect})") { call.(raw) })
    assert(refusal.is_a?(OperationResult) && refusal.message == past_msg.call(want),
           "partial value #{raw.inspect} → #{want}, refused as past — #{why}")
  end

  # UNPARSEABLE → the format sentence, naming where a right one comes from.
  ["not-a-date", "2026-13-45", "tomorrow please", "2026-02-30", { "a" => 1 }, 42].each do |bad|
    refusal = refusal_of(guard("delivery_date(#{bad.inspect})") { call.(bad) })
    assert_typed_400(refusal, "delivery_date(#{bad.inspect})")
    next unless refusal.is_a?(OperationResult)

    assert(refusal.message == "invalid delivery_date: #{bad} — use YYYY-MM-DD from the " \
                              "delivery_slots row you chose",
           "  … the FORMAT sentence: #{refusal.message.inspect}")
  end

  # PAST → the CALLER's sentence, verbatim. The two verbs word it differently and
  # neither's wording is the other's to pick, so this guard must not have one.
  [today - 1, today - 365].each do |past|
    refusal = refusal_of(guard("delivery_date(#{past})") { call.(past.iso8601) })
    assert_typed_400(refusal, "delivery_date(#{past})")
    next unless refusal.is_a?(OperationResult)

    assert(refusal.message == past_msg.call(past),
           "  … the CALLER's past_message verbatim, not a canned one: #{refusal.message.inspect}")
  end

  other = ->(d) { "a completely different sentence about #{d}" }
  refusal = refusal_of(guard("delivery_date(past, other wording)") do
    WireArguments.delivery_date((today - 1).iso8601, default: default, past_message: other)
  end)
  assert(refusal.is_a?(OperationResult) && refusal.message == other.call(today - 1),
         "a second caller's past_message is used verbatim too: #{refusal&.message.inspect}")
end

# THE CLOCK IS THE ORIGIN'S: move DeliverySlots.now and the SAME date
# flips from accepted to refused. Nothing here reads Date.today.
DAY = Date.new(2026, 8, 7)
at_dublin("2026-08-07T23:59:00") do
  pair = WireArguments.delivery_date(DAY.iso8601, default: DAY, past_message: ->(d) { "past #{d}" })
  assert(refusal_of(pair).nil?, "at 23:59 Dublin, #{DAY} is still TODAY and is accepted")
end
at_dublin("2026-08-08T00:01:00") do
  refusal = refusal_of(WireArguments.delivery_date(DAY.iso8601, default: DAY, past_message: ->(d) { "past #{d}" }))
  assert(refusal.is_a?(OperationResult) && refusal.message == "past #{DAY}",
         "two minutes later — Dublin's next day — the same date is REFUSED, so the clock read " \
         "is DeliverySlots.now and not the runner's")
end

# ── AND SO IS THE CLOCK A PARTIAL VALUE IS COMPLETED AGAINST ─────────────────
#
# The two blocks above prove the PAST test reads Dublin. This proves the same
# of the parse itself, which `Date.parse` alone could not: it fills a missing
# month or week from the PROCESS's today, so on a server a day ahead of or
# behind Dublin the SAME string named a different month. Two minutes apart,
# either side of a Dublin month boundary and of a Dublin week boundary, the
# same string resolves to a different date — and it is DeliverySlots.now that
# moved, nothing else.
puts "\n── delivery_date: a PARTIAL value is completed against the origin's today ──"
LATE = ->(d) { "past #{d}" }
at_dublin("2026-09-30T23:59:00") do
  refusal = refusal_of(WireArguments.delivery_date("1st", default: Date.new(2026, 9, 30), past_message: LATE))
  assert(refusal.is_a?(OperationResult) && refusal.message == "past 2026-09-01",
         "at 23:59 Dublin on 30 September, a bare \"1st\" completes to 2026-09-01 (this month's, past)")
end
at_dublin("2026-10-01T00:01:00") do
  pair = WireArguments.delivery_date("1st", default: Date.new(2026, 10, 1), past_message: LATE)
  assert(refusal_of(pair).nil? && value_of(pair) == Date.new(2026, 10, 1),
         "two minutes later — Dublin's next MONTH — the same \"1st\" is 2026-10-01 and is accepted")
end
at_dublin("2026-09-05T12:00:00") do
  refusal = refusal_of(WireArguments.delivery_date("Tue", default: Date.new(2026, 9, 5), past_message: LATE))
  assert(refusal.is_a?(OperationResult) && refusal.message == "past 2026-09-01",
         "on Saturday 5 September, a bare \"Tue\" is this week's — 2026-09-01, already past")
end
at_dublin("2026-09-06T12:00:00") do
  pair = WireArguments.delivery_date("Tue", default: Date.new(2026, 9, 6), past_message: LATE)
  assert(refusal_of(pair).nil? && value_of(pair) == Date.new(2026, 9, 8),
         "one day later — Dublin's next WEEK — the same \"Tue\" is 2026-09-08 and is accepted")
end

# THE FORMS THEMSELVES DID NOT MOVE, only the clock they complete against. With
# the origin's today set to the runner's own today, {WireArguments.parse_date}
# and `Date.parse` agree on every form this file names and on every value
# neither can read — so the fix bought a clock and changed no contract. (WHICH
# forms should be accepted is not settled here and is not this file's to settle.)
puts "\n── delivery_date: the accepted forms are still exactly Date.parse's ──"
at_dublin("#{Date.today.iso8601}T12:00:00") do
  %w[2026-09-01 20260101 09/01/2026 12/09/2026 1/9/2026 Tue tue Tuesday Mon Sun sep sept September
     1st 3rd 26 31st 2026 2026-09 09-2026 Sep-2026 2026-250 2026-W36-2 250 W36 W36-2 366 000 32
     13/13 Tue3rd Sep-Tue Tue12:00 09 ---09 --09-01 not-a-date 2026-13-45 2026-02-30 tomorrow
     12:00 7-Sep-2026 Sep7 2026/09/01].each do |raw|
    theirs = begin
      Date.parse(raw)
    rescue StandardError
      :refused
    end
    ours = begin
      WireArguments.parse_date(raw)
    rescue StandardError
      :refused
    end
    assert(ours == theirs, "#{raw.inspect}: parse_date → #{ours}, Date.parse → #{theirs}")
  end
end

# ── 7. past_date/1 and past_slot/3 — the domain, not an empty list ───────────
#
# Spec §9.1's first branch: a value the verb's domain does not contain is a 400
# naming what IS acceptable, never `200 []` — an empty list already means "that
# day's windows have all begun", which is a different answer.
puts "\n── past_date / past_slot: outside the domain is a 400, never an empty list ──"
at_dublin("2026-08-07T11:00:00") do
  today = DeliverySlots.now.to_date
  assert(guard("past_date(today)") { WireArguments.past_date(today) }.nil?,
         "past_date(today) → nil: TODAY is bookable, the boundary is the DAY")
  assert(guard("past_date(tomorrow)") { WireArguments.past_date(today + 1) }.nil?,
         "past_date(tomorrow) → nil")

  refusal = guard("past_date(yesterday)") { WireArguments.past_date(today - 1) }
  assert_typed_400(refusal, "past_date(#{today - 1})")
  if refusal.is_a?(OperationResult)
    assert(refusal.message.include?(today.iso8601) && refusal.message.include?("Europe/Dublin"),
           "  … names the floor and the zone: #{refusal.message}")
    assert(refusal.hint.to_s.include?("EMPTY list"),
           "  … and says why this is not the empty-list answer: #{refusal.hint}")
  end

  # 08:00 and 10:00 have begun at 11:00 Dublin; 12:00 has not.
  [1, 2].each do |slot|
    refusal = guard("past_slot(#{slot})") { WireArguments.past_slot(today, slot, "choose a later slot") }
    assert_typed_400(refusal, "past_slot(today, #{slot})")
    next unless refusal.is_a?(OperationResult)

    assert(refusal.message.include?("has already started") && refusal.message.end_with?("choose a later slot"),
           "  … names the window and carries the caller's tail: #{refusal.message}")
  end
  [3, 4, 5, 6].each do |slot|
    assert(guard("past_slot(#{slot})") { WireArguments.past_slot(today, slot, "tail") }.nil?,
           "past_slot(today, #{slot}) → nil at 11:00 Dublin (that window has not begun)")
  end
end

# ── 8. served_district/1 and missing_address/0 — ADDRESS-UPFRONT ────────────
puts "\n── served_district / missing_address: the one served-district rule ──"
pair = guard("served_district(in-zone)") { WireArguments.served_district("42 Camden Street, Dublin 2") }
assert(refusal_of(pair).nil? && value_of(pair) == "D02",
       "an in-zone address resolves to its canonical routing key (D02), got #{pair.inspect}")

["Dublin 24", "10 Downing St, London", "123 Demo Street, Dublin", "", nil].each do |bad|
  refusal = refusal_of(guard("served_district(#{bad.inspect})") { WireArguments.served_district(bad) })
  assert_typed_400(refusal, "served_district(#{bad.inspect})")
end

assert_typed_400(WireArguments.missing_address, "missing_address")
assert(WireArguments.missing_address.message ==
       DublinZones.reject_message(DublinZones::Result.new(ok: false, district: nil, reason: :blank)),
       "missing_address is the SAME sentence DublinZones gives for an address it never got")

# ── 9. missing/1 — the sentence every verb answers an absent argument with ───
puts "\n── missing: one sentence for an argument that was not given ──"
["delivery_slot_id", "delivery_address — delivery is part of the order"].each do |field|
  refusal = WireArguments.missing(field)
  assert_typed_400(refusal, "missing(#{field.inspect})")
  assert(refusal.message == "missing field: #{field}", "  … #{refusal.message.inspect}")
end

# ── 10. The guards run in front of the database, not behind it ──────────────
#
# Every assertion above ran with ActiveRecord never loaded, which is only
# possible if these checks precede the connection.
puts "\n── the whole module ran with no database ──"
assert(!defined?(ActiveRecord::Base),
       "every guard above answered without ActiveRecord loaded (they precede every cast and every lock)")

if FAILURES.empty?
  puts "\nWireArguments spec: ALL PASS"
  exit 0
else
  puts "\nWireArguments spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
