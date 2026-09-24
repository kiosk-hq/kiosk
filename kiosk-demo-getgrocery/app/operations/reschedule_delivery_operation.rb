# frozen_string_literal: true

# reschedule_delivery — move an ALREADY-PAID order's delivery to a different
# window, and optionally to a new address, REUSING the payment that order
# already has. No new mandate and no second settlement: "already paid" is a
# PRECONDITION, not an instruction to settle now.
#
# Four gates, in the order they are written below. Gate 3 answers "no such
# order", "not yours" and "already rescheduled" with ONE sentence, deliberately:
# distinguishing them would let a caller enumerate other principals' order ids.
class RescheduleDeliveryOperation
  def self.call(order_id:, delivery_slot_id:, delivery_date:, delivery_address:)
    # ── Gate 1: the order is named ─────────────────────────────────────────
    return WireArguments.missing("order_id")         if order_id.blank?
    return WireArguments.missing("delivery_slot_id") if delivery_slot_id.nil?

    order_id, refusal = WireArguments.order_id(order_id, hint: WireArguments::HINT_ORDER_ID_MOVE)
    return refusal if refusal

    # ADDRESS-UPFRONT: a NEW address must also be an in-zone Dublin one.
    # Omitted → the order keeps the address it has.
    district = nil
    if delivery_address.present?
      district, refusal = WireArguments.served_district(delivery_address)
      return refusal if refusal
    end

    # THE CLOCK IS THE DELIVERY ADDRESS's. A move that names a NEW address is
    # timed at the new door; one that does not keeps the clock the order was
    # BOOKED on, which is READ OFF THE ROW inside the transaction below. Until
    # then the origin default stands in — every district this shop serves is on
    # it, and the value is re-read before anything is published.
    zone = district ? DeliverySlots.zone_for(district) : DeliverySlots.default_zone

    slot_id, refusal = WireArguments.delivery_slot_id(delivery_slot_id)
    return refusal if refusal

    # ── Gate 2: the new window ─────────────────────────────────────────────
    # Same source of truth as delivery_slots and create_order, so the day+time an
    # assistant saw is the day+time this books.
    date, refusal = WireArguments.delivery_date(
      delivery_date,
      default:      DeliverySlots.now(zone).to_date + 1,
      past_message: ->(d) { "delivery_date is in the past: #{d}" },
      zone:         zone,
    )
    return refusal if refusal

    refusal = WireArguments.past_slot(
      date, slot_id,
      "choose a later slot; call delivery_slots again for the still-bookable windows",
      zone,
    )
    return refusal if refusal

    # One transaction around the two gates and the move — the payment gate must
    # not pass for an order being moved out from under it. It joins the
    # SessionContext transaction the wire opened.
    ApplicationRecord.transaction do
      # ── Gate 3: it exists, is yours, and has not already moved ───────────
      # `pick` and not `find_by!`: the bang form raises RecordNotFound, which
      # Rails maps to 404 and the mixin's `rescue_from` floor renders as
      # `not_found` — telling a prober that the id is unknown, which is the one
      # thing this refusal is worded to avoid. The ADDRESS and the TIMEZONE are
      # read here because `update_all` cannot resolve "keep the old one" in SQL,
      # and because a move that names no new address must land on the clock this
      # order was booked on rather than on one re-parsed out of its address.
      order = Order.owned_by_current_principal
                   .reschedulable
                   .where(id: order_id)
                   .pick(:id, :address, :timezone)
      if order.nil?
        next OperationResult.refused(
          code:    "forbidden",
          message: "order not found, not yours, already rescheduled (one reschedule per order), " \
                   "or already with the courier",
        )
      end

      # ── Gate 4: a settlement of THIS principal for THIS order ────────────
      # The payer must be the caller (`of_current_principal`, the GUC predicate)
      # and the settled cart must name this order ({CartMandate.referencing},
      # shared with the pay path and the back office): paying for A moves no B.
      paid = Settlement.of_current_principal
                       .joins(:cart_mandate)
                       .merge(CartMandate.referencing(order_id))
      unless paid.exists?
        # An order with a capture OUTSTANDING is neither paid nor unpaid, and
        # "this order is not paid yet" is the sentence protocol.md §11.6
        # forbids about one — it sends the assistant back to sign a fresh chain.
        # The claim is owner-scoped (see ValidatingPaymentProvider).
        if Order.owned_by_current_principal.where(id: order_id, status: Order::PAYING).exists?
          next OperationResult.refused(
            code:    "forbidden",
            message: "a payment for this order is in progress and its outcome is not yet known — " \
                     "re-read my_orders and reschedule once its payment_state is `paid`; do NOT sign " \
                     "a fresh mandate chain while it reads `pending`",
          )
        end

        next OperationResult.refused(
          code:    "forbidden",
          message: "this order is not paid yet — reschedule_delivery only moves an ALREADY-PAID " \
                   "order (it reuses the existing settlement, it does not settle now). Pay for " \
                   "the order first via the normal pay flow (a cart mandate whose line_items " \
                   "include {\"order_id\": \"#{order_id}\"}), THEN call reschedule_delivery — or, " \
                   "if the window is what you want to change before paying, place the order you " \
                   "want with create_order and leave this one unpaid",
        )
      end

      row_id, current_address, current_timezone = order
      # The address this move lands at — the new one when given, the order's own
      # otherwise — and therefore the clock the window is written on.
      landing_address = delivery_address.to_s.presence || current_address
      # AND THE CLOCK COMES FROM THE MOVE OR FROM THE ROW, NEVER FROM A PARSE OF
      # STORED TEXT. A new address has been routed to a served district by gate 1,
      # so `district` is that district and the zone is its declared one; a move
      # that names none keeps the zone the order was quoted on, which the row
      # carries. Running the address parser here would hand an address that no
      # longer resolves — hand-edited, restored from a dump — the ORIGIN default
      # with nothing saying so, and publish the window on a clock nobody chose.
      zone    = district ? DeliverySlots.zone_for(district) : Time.find_zone!(current_timezone)
      slot_at = DeliverySlots.slot_at(date, slot_id, zone)

      Order.owned_by_current_principal
           .where(id: row_id)
           .update_all(
             status:     Order::RESCHEDULED,
             slot_at:    slot_at,
             # `to_s.presence` and not `presence`: the TEXT the value renders as
             # is what decides "was a new address given", and what gets stored.
             address:    landing_address,
             # The clock the NEW window was written on, stored beside it — a
             # move to another district moves this with it, and a move that
             # keeps the address writes back what it read.
             timezone:   zone.name,
             updated_at: Time.current,
           )

      # AND THE COURIER IS RE-ARMED AGAINST THE NEW WINDOW. The departure is
      # `slot_at` minus the shop's lead, so moving the window moves it; the run
      # the OLD schedule still produces finds the row not yet due and hands
      # itself back to the new one.
      CourierDispatchJob.arm!(row_id)

      # The label travels beside the instant here for the same reason it does
      # on `delivery_slots`, `create_order` and `my_orders`: this is the fourth
      # verb that publishes this window, and a window published without its zone
      # is the one an assistant reads back an hour wrong.
      OperationResult.ok({ order_id:         order_id,
                           rescheduled_at:   slot_at.iso8601,
                           rescheduled_label: DeliverySlots.label(slot_at, zone),
                           timezone:          zone.name })
    end
  end
end
