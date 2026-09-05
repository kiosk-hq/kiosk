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
  # The two "where do I get one of these" tails. Both verbs take an `order_id`
  # but ask for different things — create_order one it may still replace,
  # reschedule_delivery one that is already paid for.
  HINT_ORDER_ID_REPLACE = "pass the `order_id` a previous create_order returned " \
                          "(or omit it to place a new order)"
  HINT_ORDER_ID_MOVE    = "pass the `order_id` from my_orders or create_order"

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
  # resolved and BEFORE the replace path, so an unpriceable cart never takes a
  # row lock.
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
    return [raw, nil] if UuidCheck.valid?(raw)

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
  # THE SHAPE IS THE SCHEMA'S, NOT `.to_i`'s. A `raw.to_s.to_i` is enough to stop
  # the 500s the header describes and NOT enough to agree with the
  # `{type: "integer", minimum: 1, maximum: 6}` declared in front of it:
  # `1.5.to_s.to_i` is 1, so a fractional slot comes out of that line INSIDE the
  # declared range — booked as slot 1 rather than refused. Every other hostile
  # shape (`true`, `false`, `[]`, `{}`, `[1]`, `{"a" => 1}`, `"abc"`) collapses
  # to 0 and the range arm below catches it, so `1.5` is the single value on
  # which the looser spelling would disagree with the layer in front of it —
  # which is exactly as much disagreement as a defence-in-depth layer is allowed
  # to have. Not reachable on the wire either way: both verbs are `kind :action`,
  # so a real `1.5` is a JSON number the validator refuses before this line. That
  # is WHY the strict spelling matters — a layer that only holds while the layer
  # in front of it holds is not a second layer at all.
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
  # `Date.parse`, deliberately, and NOT the stricter `Date.iso8601`: what it
  # loosely accepts — a `["2026-09-01"]`, a bare `"20260101"` — is published
  # behaviour on this verb pair.
  #
  # @param default [Date] what a blank value means (tomorrow, for both verbs)
  # @param past_message [Proc] the refusal sentence for a past date; the two
  #   verbs word it differently and neither's wording is the other's to pick.
  # @return [Array(Date, nil), Array(nil, OperationResult)]
  def delivery_date(raw, default:, past_message:)
    return [default, nil] if raw.blank?

    date = begin
      Date.parse(raw.to_s)
    rescue ArgumentError, TypeError
      return [nil, OperationResult.refused(
        code:    "bad_request",
        message: "invalid delivery_date: #{raw} — use YYYY-MM-DD from the delivery_slots row you chose",
      )]
    end
    # ONE CLOCK FOR THE WHOLE ORIGIN. `DeliverySlots.now` and not
    # `Date.today`, which reads the SERVER process's zone: this and {#past_date}
    # answer the same «is this day already gone?», and around midnight a
    # server-zone answer differs from the Europe/Dublin one — so `delivery_slots`
    # could refuse a day `create_order` still accepts.
    return [date, nil] unless date < DeliverySlots.now.to_date

    [nil, OperationResult.refused(code: "bad_request", message: past_message.call(date))]
  end

  # A window that has already begun is no longer bookable, and BOTH verbs
  # re-validate it so neither lands on a window `delivery_slots` would now hide.
  # Whole past DAYS are caught above; this is a past TIME-OF-DAY today.
  #
  # @return [OperationResult, nil] a refusal, or nil when the window is bookable
  def past_slot(date, slot_id, tail)
    return nil unless DeliverySlots.past?(date, slot_id)

    OperationResult.refused(
      code:    "bad_request",
      message: "delivery slot #{slot_id} on #{date} has already started " \
               "(#{DeliverySlots.slot_at(date, slot_id).iso8601}) — #{tail}",
    )
  end

  # ── A DELIVERY DATE IN THE PAST IS OUTSIDE ITS DOMAIN ────────────────────
  #
  # Spec §9.1's first branch: a value the verb's domain does not contain is
  # `400 bad_request` naming what is acceptable, never an empty list — `200 []`
  # for a past date is byte-identical to the honest empty answer for TODAY once
  # the last window has begun. A guard rather than an `enum` because the domain
  # ("today or later, Europe/Dublin") rolls forward every midnight. TODAY is not
  # refused: the boundary is deliberately the DAY and not the window.
  #
  # @return [OperationResult, nil] a refusal, or nil when the date is bookable
  def past_date(date)
    today = DeliverySlots.now.to_date
    return nil if date >= today

    OperationResult.refused(
      code:    "bad_request",
      message: "date #{date.iso8601} is in the past — getgrocery delivers from #{today.iso8601} " \
               "onwards (Europe/Dublin)",
      hint:    "pass #{today.iso8601} or a later date; an EMPTY list means that day's windows " \
               "have all begun, which is a different answer from this one.",
    )
  end

  # ADDRESS-UPFRONT. Every surface that takes a delivery address checks
  # it against the SAME served-Dublin-district rule, so an address that got slots
  # can always be ordered to. FORMAT + ZONE only: the operator cannot tell a
  # plausible in-zone address from a real one — the human must confirm it.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)] the canonical `D0N`
  #   routing key the address resolved to, or a refusal naming what is needed.
  #   `delivery_slots` publishes the zone; the order verbs only need one to exist.
  def served_zone(address)
    result = DublinZones.check(address)
    return [result.zone, nil] if result.ok?

    [nil, OperationResult.refused(code: "bad_request", message: DublinZones.reject_message(result))]
  end

  # The blank-address refusal `delivery_slots` answers with — the same sentence
  # {DublinZones} gives for an address it was never handed.
  def missing_address
    OperationResult.refused(
      code:    "bad_request",
      message: DublinZones.reject_message(DublinZones::Result.new(ok: false, zone: nil, reason: :blank)),
    )
  end

  # The cart. The declared `input_schema` says `array of {sku, qty}` and
  # nothing at the wire enforces it, so this is where `items: "x"`,
  # `items: {sku: …}` and `items: ["bread"]` become a 400 instead of walking into
  # `.map` / `it[:sku]` and raising a 500 out of the headline action.
  #
  # `qty` IS AS STRICT HERE AS IN THE SCHEMA, and that is the point. A
  # `(item[:qty] || 1).to_s.to_i` stops the 500s the header describes but lets
  # exactly two shapes through as a legal quantity: `false`, because `||` reads
  # it as absent and defaults to 1, and `1.5`, because `"1.5".to_i` is 1.
  # Neither is reachable on the wire — `input_schema` declares `qty`
  # `{type: "integer", minimum: 1}` and `required`, and it is validated on every
  # call — so this layer would never be the thing refusing them. That is
  # precisely why it is written strictly: a defence-in-depth layer whose whole
  # claim is «the schema is not the only thing standing here» is worth nothing
  # if the schema is, in fact, the only thing standing. An ABSENT `qty` is
  # refused too, for the same reason: the schema requires it, so a default here
  # would be a second, weaker contract nobody published.
  #
  # BOTH ENDS OF THE DECLARED RANGE: `qty` is
  # `{type: "integer", minimum: 1, maximum: MAX_INT4}`, so this layer carries a
  # `<= MAX_INT4` arm as well as its `>= 1` one. Leaving it off would be the
  # same defect one bound over — a second layer weaker than the schema in
  # front of it. What this layer CANNOT
  # check is the other half of the same bug: the cart's TOTAL, which is not a
  # fact about any single item. {#priceable_total} answers that one, later,
  # once the catalogue prices are resolved.
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
