# frozen_string_literal: true

# create_order — place (or REPLACE) one grocery order for the authenticated
# principal, with its delivery window and address, and quote the total a cart
# mandate must be signed against.
#
# SEVEN GATES, in the order they are written below, and the order is behaviour
# rather than tidiness — each one is the answer a caller gets when a later one
# would also have refused: the cart's shape (K-693), delivery given and in-zone
# (K-468), the window still bookable (K-470/480), the skus, the age gate, the
# priceable total (K-1047), the replace lock. Gate 5 comes AFTER the sku
# resolution because it is a fact about the RESOLVED products, and BEFORE the
# order_id shape check because an un-attested agent should be told to go and get
# attested rather than told its id is malformed. Gate 6 can only be asked once
# gate 4 has resolved the prices — it bounds their SUM — and it is asked BEFORE
# the replace path so a cart nobody can price never takes a row lock.
class CreateOrderOperation
  # The anonymized booleans an age-restricted cart demands. Named once, so the
  # gate, its refusal sentence and its hint cannot come to disagree.
  REQUIRED_KYC_ATTRIBUTES = %w[age_over_18].freeze

  # @param principal_id [String] the account the wire resolved, NEVER an argument
  #   off the request — which is why a forged `user_id` in the body is ignored.
  #   An INSERT is the one place the principal must be spelled in Ruby: every
  #   READ hides it in `Order.owned_by_current_principal`'s WHERE predicate, and
  #   an INSERT has no predicate to hide it in.
  # @param items [Object] the raw cart, already unwrapped from
  #   ActionController::Parameters by the controller — its ELEMENT TYPE is a
  #   decision gate 1 makes, so it may not arrive as a controller type.
  def self.call(principal_id:, items:, delivery_slot_id:, delivery_date:, delivery_address:, order_id:)
    # ── Gate 1: the cart ───────────────────────────────────────────────────
    items, refusal = WireArguments.items(items)
    return refusal if refusal

    # ── Gate 2: delivery is part of the order ──────────────────────────────
    # Presence of BOTH fields first, then the zone, then the window's range: the
    # sequence decides which of two wrong arguments a caller hears about first.
    return WireArguments.missing("delivery_slot_id — delivery is part of the order") if delivery_slot_id.nil?
    return WireArguments.missing("delivery_address — delivery is part of the order") if delivery_address.blank?

    _zone, refusal = WireArguments.served_zone(delivery_address)
    return refusal if refusal

    slot_id, refusal = WireArguments.delivery_slot_id(delivery_slot_id)
    return refusal if refusal

    # ── Gate 3: the window, on the day the assistant saw it (K-470) ────────
    # An omitted delivery_date falls back to tomorrow, for callers that pre-date
    # the field — but a caller that saw a slot for a day SHOULD pass that day.
    date, refusal = WireArguments.delivery_date(
      delivery_date,
      default:      DeliverySlots.now.to_date + 1,
      past_message: ->(d) { "delivery_date is in the past: #{d} — choose a current/future delivery slot" },
    )
    return refusal if refusal

    slot_at = DeliverySlots.slot_at(date, slot_id)
    refusal = WireArguments.past_slot(
      date, slot_id,
      "choose a later slot; call delivery_slots again for the still-bookable windows",
    )
    return refusal if refusal

    # ONE transaction: the replace path reads a row under a lock and then
    # rewrites its items, and those must not be separable. It joins the
    # SessionContext transaction the wire already opened (where the GUCs
    # `owned_by_current_principal` reads are SET LOCAL), so it states what
    # belongs together rather than opening a second unit of atomicity. `next` and
    # never `return`: nothing here needs a non-local exit out of the block.
    ApplicationRecord.transaction do
      # ── Gate 4: every sku exists ─────────────────────────────────────────
      # Deliberately NOT `Product.in_stock`: the catalogue HIDES an out-of-stock
      # line, but an order naming one is a stock question, not an unknown-sku one.
      skus   = items.map { |item| item[:sku] }.uniq
      by_sku = Product.where(sku: skus)
                      .pluck(:sku, :id, :price_cents, :age_restricted)
                      .to_h { |sku, id, price_cents, age_restricted|
                        [sku, { id: id, price_cents: price_cents, age_restricted: age_restricted }]
                      }

      missing = skus.reject { |sku| by_sku.key?(sku) }
      unless missing.empty?
        next OperationResult.refused(code:    "bad_request",
                                     message: "unknown sku(s): #{missing.join(", ")}")
      end

      # ── Gate 5: the alcohol age gate ─────────────────────────────────────
      # Any age_restricted product in the cart, and the agent must carry an
      # engine-verified age_over_18 attestation. Only booleans a valid
      # broker-signed attestation granted ever reach `kyc_attributes` (POST
      # /kiosk/agents/kyc rejects a bad signature), so nothing self-asserted
      # passes here. {Product.age_restricted?} reads the flag fail-closed.
      restricted = items.any? { |item| Product.age_restricted?(by_sku[item[:sku]][:age_restricted]) }
      if restricted && !Agent.kyc_granted?(*REQUIRED_KYC_ATTRIBUTES)
        next OperationResult.refused(
          code:    "kyc_required",
          message: "this cart contains an age-restricted (alcohol) item — an 18+ verification " \
                   "is required to order it",
          hint:    "POST <endpoint>/request_kyc to start an 18+ (age_over_18) verification: " \
                   "it returns a verification_url for the human to approve; then poll " \
                   "GET <endpoint>/kyc_status for the signed attestation and submit it to " \
                   "POST <endpoint>/agents/kyc, then retry create_order",
        )
      end

      total_cents = items.sum { |item| by_sku[item[:sku]][:price_cents].to_i * item[:qty] }

      # ── Gate 6: the cart has to be PRICEABLE (K-1047) ────────────────────
      # Every `qty` here is one the published descriptor calls valid, and the
      # SUM is still bounded by `orders.total_cents`. Without this the INSERT
      # below raised `ActiveModel::RangeError` in Ruby and the wire answered
      # `500 action_failed` for an argument a client simply got wrong.
      refusal = WireArguments.priceable_total(total_cents)
      next refusal if refusal

      # The APP clock, not `now()`: `insert_all`/`update_all` type-cast their
      # values and cannot pass an SQL expression through. App and database run on
      # one host here, so it is the same clock `my_orders` then orders by.
      now = Time.current

      replaced = nil
      if order_id.present?
        # K-579: ActiveRecord does not refuse junk, it CASTS it — an unparseable
        # uuid becomes NULL and matches nothing, so without this check the caller
        # hears "not replaceable" rather than "that is not an id".
        order_id, refusal = WireArguments.order_id(order_id, hint: WireArguments::HINT_ORDER_ID_REPLACE)
        next refusal if refusal

        # ── Gate 7: replaceable, AND held while we replace it (K-544) ──────
        # Two conditions and one lock, and all three ARE the pay-race fix:
        #   · `replaceable` excludes `paying` as well as the terminal states — a
        #     /pay mid-flight has already checked its cart against these items,
        #     so swapping them now is "pay cheap, receive expensive";
        #   · the NOT EXISTS refuses an order some settled cart already
        #     references, whatever its local status says;
        #   · `lock` is `FOR UPDATE` on the orders row, serializing this replace
        #     against the pay path's atomic `created → paying` claim.
        # {CartMandate.referencing} is the same predicate the pay path and the
        # operator's back office read.
        settled = Settlement.select(Arel.sql("1"))
                            .joins(:cart_mandate)
                            .merge(CartMandate.referencing(order_id))
        replaced = Order.owned_by_current_principal
                        .replaceable
                        .where(id: order_id)
                        .where.not(settled.arel.exists)
                        .lock
                        .pick(:id)

        if replaced
          OrderItem.where(order_id: replaced).delete_all
          Order.where(id: replaced).update_all(
            total_cents: total_cents,
            slot_at:     slot_at,
            address:     delivery_address.to_s,
            updated_at:  now,
          )
        end
      end

      # `insert!` and NOT `create!`, and the reason is a wire answer rather than
      # taste: `create!` interposes validations, so `belongs_to :user` would turn
      # a principal with no `users` row from the `InvalidForeignKey` Postgres
      # raises — unmapped in `rescue_responses`, so a 500 — into a
      # `RecordInvalid`, which Rails maps to 422 and the mixin's floor renders as
      # a 400. No `id` is supplied either: generating it belongs to the column
      # DEFAULT (`gen_random_uuid()`), not to a caller-facing verb (K-654).
      new_order_id = replaced || Order.insert!(
        { user_id:     principal_id,
          status:      Order::CREATED,
          total_cents: total_cents,
          slot_at:     slot_at,
          address:     delivery_address.to_s,
          created_at:  now,
          updated_at:  now },
        returning: %i[id],
      ).first["id"]

      # `insert_all!` and not `insert_all`, so a product row that vanished
      # between the lookup above and here still raises InvalidForeignKey rather
      # than being silently skipped.
      OrderItem.insert_all!(
        items.map { |item|
          { order_id:   new_order_id,
            product_id: by_sku[item[:sku]][:id],
            qty:        item[:qty],
            created_at: now,
            updated_at: now }
        },
      )

      OperationResult.ok({
        order_id:    new_order_id,
        total_cents: total_cents,
        total_eur:   Product.format_eur(total_cents),
        currency:    "eur",
        slot_at:     slot_at.iso8601,
        pay_hint:    "pay in EUR with a cart mandate whose line_items mirror this order: " \
                     "one {\"order_id\": \"#{new_order_id}\"} entry plus one " \
                     "{\"sku\", \"qty\", \"price_cents\"} entry per item at catalog prices — " \
                     "the operator verifies currency, prices, and total before charging",
      })
    end
  end
end
