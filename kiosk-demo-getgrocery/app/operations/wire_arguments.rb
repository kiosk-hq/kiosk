# frozen_string_literal: true

# Argument checks the verbs' input schemas cannot express. Each raises a 400.
module WireArguments
  # PostgreSQL `integer`: the width of `order_items.qty` and `orders.total_cents`.
  MAX_INT4 = 2_147_483_647

  ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/

  module_function

  # @return [String] the served district the address routes to, e.g. "D02"
  def served_district(address)
    result = DublinZones.check(address)
    return result.district if result.ok?

    refuse DublinZones.reject_message(result)
  end

  # A cart whose total does not fit `orders.total_cents`.
  def priceable_total!(total_cents)
    return if total_cents <= MAX_INT4

    refuse "this cart totals #{total_cents} cents, more than this operator can put on one order " \
           "(max #{MAX_INT4})",
           hint: "order fewer units, or split the cart across several orders — the total is each " \
                 "line's catalogue price times its qty, summed."
  end

  # A real calendar day that has not passed at the delivery address.
  def delivery_date(raw, zone:)
    date = calendar_day(raw) || refuse("invalid delivery_date: #{raw} — use YYYY-MM-DD from the delivery_slots row you chose")
    refuse "delivery_date is in the past: #{date}" if date < zone.today

    date
  end

  def bookable_slot!(date, slot_id, zone)
    return unless DeliverySlots.closed?(date, slot_id, zone)

    refuse "delivery slot #{slot_id} on #{date} closes too soon to deliver an order placed now " \
           "(#{DeliverySlots.slot_at(date, slot_id, zone).iso8601}) — choose a later slot; call " \
           "delivery_slots again for the still-bookable windows"
  end

  # The day a caller named, read on its own calendar (`Kiosk-Timezone`, else the
  # address's), as the shop's day it starts on. A day that has entirely ended
  # for the caller is refused; one it is still in is answered.
  #
  # @return [Date] on the shop's calendar, never before `soonest`
  def caller_day(date, zone:, caller_zone:, soonest:)
    from  = caller_zone || zone
    start = date.in_time_zone(from)
    if start.tomorrow.past?
      floor = from.today
      refuse "date #{date.iso8601} is in the past on the calendar it is read in (#{from.name}); " \
             "the earliest day you can ask for is #{floor.iso8601}",
             hint: "pass #{floor.iso8601} or later. The day is read in YOUR calendar when you " \
                   "declare Kiosk-Timezone, and in the delivery address's when you do not."
    end

    [start.in_time_zone(zone).to_date, soonest].max
  end

  def calendar_day(raw)
    Date.iso8601(raw.to_s) if ISO_DATE.match?(raw.to_s)
  rescue Date::Error
    nil
  end

  def refuse(message, hint: nil)
    raise Kiosk::Server::Errors::BadRequest.new(message, hint: hint)
  end
end
