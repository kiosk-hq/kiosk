# frozen_string_literal: true

# THE SHAPE GUARDS getgrocery's verbs open with — expressed once, as REFUSALS
# rather than as rendered responses. NOT Operations: they write nothing, so both
# halves of the origin use them — the query handlers directly, the write
# Operations before they touch a transaction.
#
# WHY A UUID GUARD, when the database has a uuid type:
# `where(id: junk)` does not raise. ActiveRecord does not refuse junk, it CASTS
# it — an unparseable value becomes NULL and matches no row, so without the check
# a typo is answered as an OWNERSHIP refusal (403) rather than a shape one (400).
# A well-formed but foreign id still gets the 403, so the guard never softens the
# access answer.
#
# The second class of guard is not about SQL: a bare `.to_i` is answered by every
# String, Integer and Float and by no Array, Hash or boolean, so a hostile shape
# comes back 500 for an argument the published `input_schema` says is an integer.
# Reading through `to_s` first is the whole fix FOR THE 500 — it is not the whole
# fix for the guard's own contract, and BOTH declared integers on this surface
# (`items[].qty` and `delivery_slot_id`) say so: a coercion that answers
# everything also ACCEPTS shapes the schema refuses, which reads as defence in
# depth while being nothing of the kind. Both go through {#whole_number}, which
# is JSON Schema's own `integer` and nothing looser.
module WireArguments
  # The "where do I get one of these" tail. One verb on this surface takes an
  # `order_id` — `reschedule_delivery`, which wants one that is already paid
  # for — and the tail travels as an argument so the refusal sentence and the
  # verb that asks for it cannot come to disagree.
  HINT_ORDER_ID_MOVE = "pass the `order_id` from my_orders or create_order"

  module_function

  # PostgreSQL `integer` — the width of BOTH columns one cart can overrun,
  # `order_items.qty` and `orders.total_cents`, which is why one constant serves
  # the two bounds below and the descriptor that declares the first of them.
  #
  # THE BOUND IS THE COLUMN'S AND NOT A POLICY: this refuses exactly what cannot
  # be REPRESENTED and invents no basket size, so every cart the columns can
  # hold still works and only the ones that would CRASH are refused.
  MAX_INT4 = 2_147_483_647

  # ── A CART NOBODY CAN PRICE IS A 400, NOT A 500 ───────────────────────────
  #
  # Every `qty` the descriptor declares valid is a body the wire ACCEPTS, and
  # the order's total is `price_cents * qty` summed — which passes
  # `orders.total_cents` long before any single `qty` reaches its own ceiling:
  # at the catalogue's cheapest 89-cent row it takes 24_129_030 units, a legal
  # `order_items.qty`. `Order.insert!` would then raise `ActiveModel::RangeError`
  # in RUBY, before any SQL (`insert_all` type-casts its values), and the
  # executor's `rescue StandardError` would serve that as `500 action_failed` —
  # a crash for an argument a client simply got wrong.
  #
  # WHY THIS IS NOT IN `input_schema`, where `qty`'s own ceiling now is: the
  # bound is on a SUM of the OPERATOR's catalogue prices, and no per-property
  # JSON Schema keyword can express one. So the published contract splits in
  # two — the schema declares the half it can (`maximum` on `qty`) and
  # `create_order`'s own description states this half in words — and this is the
  # half that has to be a handler refusal. It is asked as soon as the prices are
  # resolved and before anything is written, so an unpriceable cart never
  # reaches the table.
  #
  # @return [OperationResult, nil] a refusal, or nil when the cart can be totalled
  def priceable_total(total_cents)
    return nil if total_cents <= MAX_INT4

    OperationResult.refused(
      code:    "bad_request",
      message: "this cart totals #{total_cents} cents, more than this operator can put on one " \
               "order (max #{MAX_INT4})",
      hint:    "order fewer units, or split the cart across several orders — the total is each " \
               "line's catalogue price times its qty, summed.",
    )
  end

  # An order id a verb was given. PRESENCE is the caller's question — the verbs
  # disagree about whether one is required — so this answers only "is it shaped
  # like an id".
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def order_id(raw, hint:)
    return [raw, nil] if Kiosk::UuidCheck.valid?(raw)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "order_id #{raw.to_s.inspect} is not a uuid — #{hint}",
    )]
  end

  # The delivery window, 1..DeliverySlots::COUNT.
  #
  # SHAPE AND RANGE, in that order. Whether the argument was GIVEN is asked
  # separately, by each verb: they word that refusal differently AND ask it at
  # different points in their sequence — create_order checks slot and address
  # for presence before validating either, so `{delivery_slot_id: 0,
  # delivery_address: ""}` is answered about the ADDRESS, and folding presence in
  # here would reorder that.
  #
  # THE SHAPE IS THE SCHEMA'S, NOT `.to_i`'s. A `raw.to_s.to_i` stops the 500s
  # the header describes and does NOT agree with the
  # `{type: "integer", minimum: 1, maximum: 6}` declared in front of it:
  # `1.5.to_s.to_i` is 1, so a fractional slot comes out of that line INSIDE the
  # declared range — booked as slot 1 rather than refused. Every other hostile
  # shape (`true`, `false`, `[]`, `{}`, `[1]`, `{"a" => 1}`, `"abc"`) collapses
  # to 0 and the range arm below catches it, so `1.5` is the single value on
  # which the looser spelling would disagree with the layer in front of it. A
  # layer that only holds while the layer in front of it holds is not a second
  # layer at all.
  #
  # {#whole_number} and not `is_a?(Integer)`: `2.0` is still slot 2 here, because
  # json_schemer says a JSON `2.0` is a valid `integer` (measured).
  #
  # @return [Array(Integer, nil), Array(nil, OperationResult)]
  def delivery_slot_id(raw)
    slot = whole_number(raw)
    if slot.nil?
      return [nil, OperationResult.refused(
        code:    "bad_request",
        message: "delivery_slot_id must be a whole number 1–#{DeliverySlots::COUNT} — " \
                 "got #{raw.inspect}",
      )]
    end
    return [slot, nil] if (1..DeliverySlots::COUNT).cover?(slot)

    [nil, OperationResult.refused(
      code: "bad_request", message: "delivery_slot_id must be 1–#{DeliverySlots::COUNT}",
    )]
  end

  # The DAY of the slot the assistant chose, or the default when omitted.
  #
  # @param default [Date] what a blank value means (tomorrow, for both verbs)
  # @param past_message [Proc] the refusal sentence for a past date; the two
  #   verbs word it differently and neither's wording is the other's to pick.
  # @return [Array(Date, nil), Array(nil, OperationResult)]
  # AND IT IS READ AS PUBLISHED, NOT IN THE CALLER'S CALENDAR. This argument
  # ECHOES a value the operator itself put in a `delivery_slots` row, where a
  # bare `YYYY-MM-DD` is the day AT THE DELIVERY ADDRESS. Re-reading it in the
  # caller's own zone would break the round trip: the caller would hand back the
  # day it was offered and be booked onto a different one. An argument the
  # caller INVENTS — `delivery_slots`' own `date` — is the other case, and is
  # read in the caller's calendar by {#caller_day}.
  #
  # @param zone [ActiveSupport::TimeZone] the DELIVERY ADDRESS's clock
  def delivery_date(raw, default:, past_message:, zone: DeliverySlots.default_zone)
    return [default, nil] if raw.blank?

    date = iso_date(raw)
    if date.nil?
      return [nil, OperationResult.refused(
        code:    "bad_request",
        message: "invalid delivery_date: #{raw} — use YYYY-MM-DD from the delivery_slots row you chose",
      )]
    end
    # ONE CLOCK PER DELIVERY ADDRESS. `DeliverySlots.now(zone)` and not
    # `Date.today`, which reads the SERVER process's zone: around midnight a
    # server-zone answer differs from the address's — so `delivery_slots`
    # could refuse a day `create_order` still accepts.
    return [date, nil] unless date < DeliverySlots.now(zone).to_date

    [nil, OperationResult.refused(code: "bad_request", message: past_message.call(date))]
  end

  # ── THE CALLER'S OWN DAY, MAPPED ONTO THE SHOP'S CALENDAR ────────────────
  #
  # `delivery_slots`' `date` is a day the CALLER names — «tonight», «Friday» —
  # so it is read in the caller's calendar, which the caller states in
  # `Kiosk-Timezone`. Silence means the address's own clock.
  #
  # THE SHAPE OF THE ANSWER, and it is what makes both of the midnight
  # scenarios come out right. A calendar day is an INTERVAL, not an instant:
  #
  #   * If the caller's day has ENTIRELY ENDED by now at the address, it is
  #     genuinely past — a `400` naming the earliest day that IS askable, read
  #     on the same calendar the argument was read on.
  #   * Otherwise the caller is asking about a day that is still current or
  #     still ahead FOR THEM, so the shop answers from the day its own calendar
  #     is on when that day BEGINS — floored at the soonest day it can actually
  #     serve. At 23:05 on the 6th two hours west of a shop already five minutes
  #     into the 7th, «today» comes back as the shop's 7th with the date on
  #     every row, rather than as a refusal for a day the customer is still in.
  #
  # With no header the caller's zone IS the address's, the interval is the
  # shop's own day, and «has it ended» is exactly `date < today`.
  #
  # @param date [Date] the day the caller named, already shape-checked
  # @param zone [ActiveSupport::TimeZone] the DELIVERY ADDRESS's clock
  # @param caller_zone [ActiveSupport::TimeZone, nil] what the caller declared
  # @param soonest [Date] the earliest day this shop can serve, on `zone`
  # @return [Array(Date, nil), Array(nil, OperationResult)]
  def caller_day(date, zone:, caller_zone:, soonest:)
    from  = caller_zone || zone
    start = from.local(date.year, date.month, date.day, 0, 0, 0)
    # `.advance(days: 1)` and not `+ 86_400`: this is the next midnight on the
    # CALLER's own calendar, and across a DST transition that interval is 23 or
    # 25 hours rather than 24.
    ends  = start.advance(days: 1)

    # ONE CLOCK DECIDES AND THE SAME CLOCK ANSWERS. The comparison is between
    # INSTANTS — `ends` is the caller's next midnight, `now` is one instant
    # whichever zone renders it — so the only calendar in this decision is
    # `from`, and the refusal is written on `from` too. Asking a SECOND clock
    # whether it agrees is what this branch must never do: a shop that has not
    # yet rolled over would answer «not past» for a day this line has already
    # ruled past, the pair would come back `[nil, nil]`, and a day nobody
    # resolved would reach the slot renderer.
    return [nil, past_day_refusal(date, from)] if ends <= DeliverySlots.now(zone)

    at_shop = start.in_time_zone(zone).to_date
    [at_shop < soonest ? soonest : at_shop, nil]
  end

  # ── A DATE ON THE WIRE IS `YYYY-MM-DD`, AND NOTHING ELSE ──────────────────
  #
  # One declared type admits one spelling — the rule the wire already applies
  # to an `integer` and to a `boolean`. A MACHINE is on the other end of this
  # call, and every row `delivery_slots` hands it carries the day it is for in
  # this exact spelling, so a second way to write one buys nothing and costs the
  # ambiguous case: `09/01/2026` is day-first to some senders and month-first to
  # others, and an origin that accepts it books one of the two without telling
  # anybody which.
  #
  # `Date.iso8601` BEHIND the pattern rather than instead of it: ISO 8601 is a
  # FAMILY, and a basic `20260901`, a datetime, an ISO week date and an ordinal
  # date all parse through it where the pattern and the refusals name ONE
  # spelling. What the ISO parse is still needed for is the value that has the
  # shape and is not a day — `2026-02-30`, `2026-13-01`.
  #
  # Every verb here that takes a day declares `format: "date"`, so the wire
  # refuses the rest before a handler runs. This guard is the layer behind that
  # one, and a layer that accepts more than the layer in front of it is not a
  # second layer at all.
  ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/

  # @return [Date, nil] the day, or nil when the value is not that one spelling
  def iso_date(raw)
    value = raw.to_s
    return nil unless ISO_DATE.match?(value)

    begin
      Date.iso8601(value)
    rescue ArgumentError, TypeError
      nil
    end
  end

  # A window that has already begun is no longer bookable, and BOTH verbs
  # re-validate it so neither lands on a window `delivery_slots` would now hide.
  # Whole past DAYS are caught above; this is a past TIME-OF-DAY today.
  #
  # @return [OperationResult, nil] a refusal, or nil when the window is bookable
  def past_slot(date, slot_id, tail, zone = DeliverySlots.default_zone)
    return nil unless DeliverySlots.past?(date, slot_id, zone)

    OperationResult.refused(
      code:    "bad_request",
      message: "delivery slot #{slot_id} on #{date} has already started " \
               "(#{DeliverySlots.slot_at(date, slot_id, zone).iso8601}) — #{tail}",
    )
  end

  # ── A DELIVERY DATE IN THE PAST IS OUTSIDE ITS DOMAIN ────────────────────
  #
  # Spec §9.1's first branch: a value the verb's domain does not contain is
  # `400 bad_request` naming what is acceptable, never an empty list — `200 []`
  # for a past date is byte-identical to the honest empty answer for TODAY once
  # the last window has begun. The domain ("today or later") rolls forward every
  # midnight, so it is a guard rather than an `enum`, and TODAY is not outside
  # it: the boundary is deliberately the DAY and not the window.
  #
  # THIS WRITES THE SENTENCE AND DECIDES NOTHING. {#caller_day} is the one place
  # that asks whether a named day is past, on the one calendar that argument is
  # read in; a second predicate here would be a second clock able to disagree
  # with it. So `zone` is whichever calendar the decision was taken on — the
  # caller's when one is declared, the delivery address's when none is — and
  # both the floor and the zone name in the sentence come off that same clock,
  # which is what makes the refusal actionable: the day it names is a day the
  # caller can pass straight back.
  #
  # @param zone [ActiveSupport::TimeZone] the calendar the day was judged on
  # @return [OperationResult] the refusal
  def past_day_refusal(date, zone)
    floor = DeliverySlots.now(zone).to_date

    OperationResult.refused(
      code:    "bad_request",
      message: "date #{date.iso8601} is in the past — it has entirely ended on the calendar this " \
               "argument is read in (#{zone.name}), and the earliest day you can ask for is " \
               "#{floor.iso8601}",
      hint:    "pass #{floor.iso8601} or a later date; an EMPTY list means that day's windows " \
               "have all begun, which is a different answer from this one. The day is read in " \
               "YOUR calendar when you declare Kiosk-Timezone, and in the delivery address's " \
               "when you do not.",
    )
  end

  # ADDRESS-UPFRONT. Every surface that takes a delivery address checks
  # it against the SAME served-Dublin-district rule, so an address that got slots
  # can always be ordered to. FORMAT + ZONE only: the operator cannot tell a
  # plausible in-zone address from a real one — the human must confirm it.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)] the canonical `D0N`
  #   routing key the address resolved to, or a refusal naming what is needed.
  #   `delivery_slots` publishes that key as the row's `district`; the order
  #   verbs only need one to exist. THE METHOD IS NAMED FOR WHAT IT RETURNS: a
  #   routing key, never the clock `DeliverySlots.zone_for` reads off it.
  def served_district(address)
    result = DublinZones.check(address)
    return [result.district, nil] if result.ok?

    [nil, OperationResult.refused(code: "bad_request", message: DublinZones.reject_message(result))]
  end

  # The blank-address refusal `delivery_slots` answers with — the same sentence
  # {DublinZones} gives for an address it was never handed.
  def missing_address
    OperationResult.refused(
      code:    "bad_request",
      message: DublinZones.reject_message(DublinZones::Result.new(ok: false, district: nil, reason: :blank)),
    )
  end

  # The cart. The declared `input_schema` says `array of {sku, qty}` and
  # nothing at the wire enforces it, so this is where `items: "x"`,
  # `items: {sku: …}` and `items: ["bread"]` become a 400 instead of walking into
  # `.map` / `it[:sku]` and raising a 500 out of the headline action.
  #
  # `qty` IS AS STRICT HERE AS IN THE SCHEMA, for the reason
  # {#delivery_slot_id} gives. A `(item[:qty] || 1).to_s.to_i` lets exactly two
  # shapes through as a legal quantity: `false`, because `||` reads it as absent
  # and defaults to 1, and `1.5`, because `"1.5".to_i` is 1. An ABSENT `qty` is
  # refused too: the schema requires it, so a default here would be a second,
  # weaker contract nobody published. BOTH ENDS of the declared
  # `{type: "integer", minimum: 1, maximum: MAX_INT4}` are carried, for the same
  # reason one bound over.
  #
  # What this layer CANNOT check is the other half of the same bug: the cart's
  # TOTAL, which is not a fact about any single item. {#priceable_total} answers
  # that one, later, once the catalogue prices are resolved.
  #
  # @return [Array(Array<Hash>, nil), Array(nil, OperationResult)]
  def items(raw)
    unless raw.is_a?(Array)
      return [nil, OperationResult.refused(
        code:    "bad_request",
        message: "items must be an array of {sku, qty} objects — got " \
                 "#{raw.nil? ? "nothing" : raw.class}",
      )]
    end
    if raw.empty?
      return [nil, OperationResult.refused(code: "bad_request", message: "items must be a non-empty array")]
    end

    normalised = []
    raw.each do |item|
      unless item.is_a?(Hash)
        return [nil, OperationResult.refused(
          code:    "bad_request",
          message: "each item must be a {sku, qty} object — got #{item.class} (#{item.inspect}); " \
                   "e.g. {\"sku\": \"sourdough-bread\", \"qty\": 2}",
        )]
      end

      sku = item[:sku].to_s
      qty = whole_number(item[:qty])
      if sku.empty?
        return [nil, OperationResult.refused(code: "bad_request", message: "each item needs a sku")]
      end
      if qty.nil?
        return [nil, OperationResult.refused(
          code:    "bad_request",
          message: "qty must be a whole number >= 1 — got #{item[:qty].inspect}",
        )]
      end
      if qty < 1
        return [nil, OperationResult.refused(code: "bad_request", message: "qty must be >= 1")]
      end
      if qty > MAX_INT4
        return [nil, OperationResult.refused(
          code:    "bad_request",
          message: "qty must be <= #{MAX_INT4} — got #{qty}",
        )]
      end

      normalised << { sku: sku, qty: qty }
    end
    [normalised, nil]
  end

  # JSON Schema's `integer`, in Ruby — and nothing looser.
  #
  # NOT `is_a?(Integer)`, and the difference is measured rather than assumed:
  # draft 2020-12 defines `integer` NUMERICALLY, not by wire type, so
  # `{"qty": 2.0}` is a VALID integer and json_schemer accepts it. A bare class
  # test here would therefore refuse a call the published schema allows, which
  # is the one way this guard could get the story wrong in the other direction.
  # JSON parsing yields Integer or Float and nothing else, so those are the two
  # cases; every other type — nil, true/false, String, Array, Hash — and every
  # fractional or non-finite Float is not a quantity.
  #
  # @return [Integer, nil] nil when `raw` is not a whole number
  def whole_number(raw)
    return raw if raw.is_a?(Integer)
    return nil unless raw.is_a?(Float) && raw.finite?

    raw == raw.truncate ? raw.truncate : nil
  end

  # The sentence every verb here answers a missing argument with.
  def missing(field)
    OperationResult.refused(code: "bad_request", message: "missing field: #{field}")
  end
end
