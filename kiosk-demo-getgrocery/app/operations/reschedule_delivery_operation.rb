# frozen_string_literal: true

# reschedule_delivery — move an ALREADY-PAID order's delivery to a different
# window, and optionally to a new address, REUSING the payment that order
# already has. There is no new mandate and no second settlement: "the order must
# already be paid" is a PRECONDITION, not an instruction to settle now.
#
# THE GATES, IN THIS ORDER:
#   1. the order is named, and named as a uuid                        (K-579)
#   2. the new window is a real, still-bookable one on its day        (K-470/480)
#   3. the order exists, belongs to the principal and has not already been
#      moved — one reschedule per order, further changes go through the operator
#   4. a settlement OF THIS PRINCIPAL references THIS order
#
# Gate 3 answers "no such order", "not yours" and "already rescheduled" with ONE
# sentence, deliberately: distinguishing them would let a caller enumerate other
# principals' order ids.
class RescheduleDeliveryOperation
  def self.call(order_id:, delivery_slot_id:, delivery_date:, delivery_address:)
    # ── Gate 1: the order is named ─────────────────────────────────────────
    return WireArguments.missing("order_id")         if order_id.blank?
    return WireArguments.missing("delivery_slot_id") if delivery_slot_id.nil?

    order_id, refusal = WireArguments.order_id(order_id, hint: WireArguments::HINT_ORDER_ID_MOVE)
    return refusal if refusal

    # ADDRESS-UPFRONT (K-468): a NEW address must also be an in-zone Dublin one.
    # Omitted → the order keeps the address it has.
    if delivery_address.present?
      _zone, refusal = WireArguments.served_zone(delivery_address)
      return refusal if refusal
    end

    slot_id, refusal = WireArguments.delivery_slot_id(delivery_slot_id)
    return refusal if refusal

    # ── Gate 2: the new window ─────────────────────────────────────────────
    # Same source of truth as delivery_slots and create_order, so the day+time an
    # assistant saw is the day+time this books. Optional for backward compat →
    # tomorrow. The past-date sentence is SHORTER than create_order's, and that
    # is this verb's wording, not a candidate for convergence-by-conversion.
    date, refusal = WireArguments.delivery_date(
      delivery_date,
      default:      DeliverySlots.now.to_date + 1,
      past_message: ->(d) { "delivery_date is in the past: #{d}" },
    )
    return refusal if refusal

    refusal = WireArguments.past_slot(
      date, slot_id,
      "choose a later slot; call delivery_slots again for the still-bookable windows",
    )
    return refusal if refusal

    # One transaction around the two gates and the move, as it was: the payment
    # gate must not be able to pass for an order that is being moved out from
    # under it. It joins the SessionContext transaction the wire opened.
    ApplicationRecord.transaction do
      # ── Gate 3: ownership + state ────────────────────────────────────────
      # `pick` and not `find_by!`: the bang form raises RecordNotFound, which
      # Rails maps to 404 and the mixin's `rescue_from` floor would render as
      # `not_found` — telling a prober that the id is unknown, which is the one
      # thing this refusal is worded to avoid. The ADDRESS comes back with the
      # id because the raw UPDATE resolved "keep the old address" in SQL
      # (`COALESCE(NULLIF(:new, ''), address)`) and `update_all` has no way to
      # write an expression; reading it here is the same decision, one layer up.
      order = Order.owned_by_current_principal
                   .reschedulable
                   .where(id: order_id)
                   .pick(:id, :address)
      if order.nil?
        next OperationResult.refused(
          code:    "forbidden",
          message: "order not found, not yours, or already rescheduled (one reschedule per order)",
        )
      end

      # ── Gate 4: a settlement of THIS principal for THIS order ────────────
      # The payer must be the caller (`of_current_principal`, the GUC predicate)
      # and the settled cart must name this order ({CartMandate.referencing},
      # the containment the pay path and the back office share). Paying for order
      # A does not move order B.
      paid = Settlement.of_current_principal
                       .joins(:cart_mandate)
                       .merge(CartMandate.referencing(order_id))
      unless paid.exists?
        # K-853: an order with a capture OUTSTANDING is neither paid nor unpaid,
        # and telling an assistant "this order is not paid yet" about one is the
        # sentence protocol.md §11.6 forbids — it is what sends it back to sign a
        # fresh chain. The claim is owner-scoped (see ValidatingPaymentProvider),
        # so a `paying` row here is THIS principal's own in-flight charge.
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
                   "if you have not paid, just change the order in place with " \
                   "create_order(order_id: \"#{order_id}\", …)",
        )
      end

      row_id, current_address = order
      slot_at = DeliverySlots.slot_at(date, slot_id)

      Order.owned_by_current_principal
           .where(id: row_id)
           .update_all(
             status:     Order::RESCHEDULED,
             slot_at:    slot_at,
             # `to_s.presence` and not `presence`: the raw statement wrote
             # `NULLIF(<the value as text>, '')`, so what decides "was a new
             # address given" is the TEXT the value renders as, and what gets
             # stored is that same text.
             address:    delivery_address.to_s.presence || current_address,
             updated_at: Time.current,
           )

      OperationResult.ok({ order_id: order_id, rescheduled_at: slot_at.iso8601 })
    end
  end
end
