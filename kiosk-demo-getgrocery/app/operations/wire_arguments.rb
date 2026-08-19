# frozen_string_literal: true

# THE SHAPE GUARDS getgrocery's verbs open with — expressed once, as REFUSALS
# rather than as rendered responses (the {ListAccess} shape tudu settled, and
# {WireArguments} on hoteling and skooti).
#
# WHY THEY EXIST AT ALL, and why they did not shrink when the SQL went away.
# `order_id` used to be interpolated into a `::uuid` cast, so POSTGRES was the
# shape check: a malformed id raised InvalidTextRepresentation, which is not a
# Kiosk error and so escaped as a raw 500 leaking "invalid input syntax for type
# uuid" for what is plainly a client mistake — and on this origin that value
# also reaches the PAY path, where a 500 is the worst answer there is because an
# assistant cannot tell it from "the charge may have happened". That is K-579,
# and {UuidCheck} was the answer.
#
# The guards got MORE load-bearing under ActiveRecord (K-654), exactly as
# atablefor's, tudu's and skooti's did: `where(id: junk)` does not raise,
# because ActiveRecord's uuid type quietly casts an unparseable value to NULL,
# which matches no row — so without the check a typo would be reported as an
# OWNERSHIP refusal (403) instead of a shape one (400). ActiveRecord does not
# refuse junk, it CASTS it, and losing the database's refusal is precisely why
# the guard has to be here. A well-formed but foreign id still gets the 403, so
# the shape check never softens the access answer.
#
# WHAT IS NEW ON THIS DEMO is the second class of guard, and it is not about
# SQL at all: `delivery_slot_id` and `qty` were read with a bare `.to_i`, which
# every String, Integer and Float answers and `true`, `false`, an Array and an
# object do not — so four hostile shapes per verb raised NoMethodError and came
# back 500 `action_failed` for an argument the published `input_schema` already
# says must be an integer. Reading through `to_s` first is the whole fix: every
# value that worked reads identically (`"3"` → 3, `3.7` → 3, `"abc"` → 0), and
# the four that crashed now join the refusal `"abc"` already got. It is
# hoteling's `search_hotels` treatment applied where it was still missing.
#
# These are NOT Operations: they write nothing. Both halves use them — the query
# handlers directly, the write Operations before they touch a transaction — so
# one malformed-argument sentence serves the whole origin.
module WireArguments
  # The two "where do I get one of these" tails. Two verbs take an `order_id`
  # and they point at different places to find one, because they are asking for
  # different things: create_order wants an order it may still replace, and
  # reschedule_delivery wants one that is already paid for.
  HINT_ORDER_ID_REPLACE = "pass the `order_id` a previous create_order returned " \
                          "(or omit it to place a new order)"
  HINT_ORDER_ID_MOVE    = "pass the `order_id` from my_orders or create_order"

  module_function

  # An order id a verb was given. PRESENCE is the caller's question — the two
  # verbs disagree about whether one is required at all — so this only answers
  # "is it shaped like an id".
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
  # RANGE ONLY. Whether the argument was GIVEN is asked separately, by each
  # verb, because the two verbs word that refusal differently AND ask it at
  # different points in their sequence — create_order asks for the slot and the
  # address before it validates either, so `{delivery_slot_id: 0,
  # delivery_address: ""}` is answered about the ADDRESS. Folding presence in
  # here would quietly reorder that.
  #
  # `raw.to_s.to_i` and not `raw.to_i`: see the header. `""` reads as 0 and gets
  # the range refusal, exactly as it did.
  #
  # @return [Array(Integer, nil), Array(nil, OperationResult)]
  def delivery_slot_id(raw)
    slot = raw.to_s.to_i
    return [slot, nil] if (1..DeliverySlots::COUNT).cover?(slot)

    [nil, OperationResult.refused(
      code: "bad_request", message: "delivery_slot_id must be 1–#{DeliverySlots::COUNT}",
    )]
  end

  # The DAY of the slot the assistant chose (K-470), or the historical default
  # when it is omitted.
  #
  # `Date.parse`, deliberately, and NOT hoteling's stricter `Date.iso8601`: this
  # verb pair has always parsed its dates this way, so what it accepts — a
  # `["2026-09-01"]` it scans a date out of, a bare `"20260101"` — is published
  # behaviour and not this conversion's to change.
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
    return [date, nil] unless date < Date.today

    [nil, OperationResult.refused(code: "bad_request", message: past_message.call(date))]
  end

  # A window that has already begun is no longer bookable as a fresh delivery
  # (K-480), and BOTH verbs re-validate it so neither can land on a window
  # `delivery_slots` would now hide. Whole past DAYS are caught above; this is a
  # past TIME-OF-DAY today.
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

  # ── T-090: A DELIVERY DATE IN THE PAST IS OUTSIDE ITS DOMAIN ─────────────
  #
  # Spec §9.1's FIRST branch: a value the verb's domain does not contain is
  # `400 bad_request` NAMING what is acceptable, never an empty list.
  #
  # WHY THIS ONE NEEDED A GUARD RATHER THAN AN `enum`. The domain is "today or
  # later, in Europe/Dublin" and it rolls forward every midnight, so no enum
  # written at declaration time can name it — the same reason atablefor's
  # seating horizon keeps a guard. `format: "date"` can only say the string is
  # a calendar date.
  #
  # WHAT IT REPLACES, and why the old answer was indefensible. A date thirty
  # days back returned `200 []`, because {DeliverySlots.bookable_ids} rejects
  # every window whose start has passed — and every window of a past day has.
  # That is byte-identical to the answer for TODAY once the last window has
  # begun, which is the honest empty case this verb must keep. An assistant
  # reading `[]` could not tell "you asked for last month" from "today is sold
  # out, try tomorrow", and only one of those is worth retrying.
  #
  # TODAY IS NOT REFUSED. The boundary is deliberately the DAY and not the
  # window: today with every window begun is still a real question with a real
  # empty answer.
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

  # ADDRESS-UPFRONT (K-468). Every surface that takes a delivery address
  # validates it against the SAME served-Dublin-district rule, so an address
  # that got slots can always be ordered to and one that cannot is refused with
  # the same sentence wherever it is offered. FORMAT + ZONE only: the operator
  # still cannot verify that a plausible in-zone address is real — the human
  # must confirm it, which is the skill's job.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)] the canonical
  #   `D0N` routing key the address resolved to, or a refusal naming what is
  #   needed. `delivery_slots` publishes the zone on every row; the two order
  #   verbs only care that there is one.
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

  # The cart (K-693). The guard checks the TYPE its message always claimed: the
  # declared `input_schema` says `array of {sku, qty}`, nothing at the wire
  # enforces it, and before the check `items: "x"`, `items: {sku: …}` and
  # `items: ["bread"]` all walked into `.map` / `it[:sku]` and raised
  # NoMethodError or TypeError — a 500 for a plain client type error on the
  # flagship demo's headline action.
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
      qty = (item[:qty] || 1).to_s.to_i
      if sku.empty?
        return [nil, OperationResult.refused(code: "bad_request", message: "each item needs a sku")]
      end
      if qty < 1
        return [nil, OperationResult.refused(code: "bad_request", message: "qty must be >= 1")]
      end

      normalised << { sku: sku, qty: qty }
    end
    [normalised, nil]
  end

  # The sentence a verb raised for an argument it was not given, unchanged.
  def missing(field)
    OperationResult.refused(code: "bad_request", message: "missing field: #{field}")
  end
end
