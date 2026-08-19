# frozen_string_literal: true

# create_order — place (or REPLACE) one grocery order for the authenticated
# principal, with its delivery window and address, and quote the total a cart
# mandate must be signed against.
#
# THE GATES, IN THIS ORDER, and the order is behaviour rather than tidiness —
# each one is the answer a caller gets when a later one would also have refused,
# and the sequence below is the one the raw handler published, argument by
# argument:
#   1. the cart is a non-empty array of {sku, qty} objects            (K-693)
#   2. a delivery window and an IN-ZONE Dublin address were given     (K-468)
#   3. the window is a real one, on a day that is still bookable      (K-470/480)
#   4. every sku exists in the catalogue
#   5. an age_restricted item requires an engine-verified age_over_18 (the gate)
#   6. a replaced order is still replaceable, and is LOCKED while we replace it
#
# Gate 5 comes AFTER the sku resolution because it is a fact about the RESOLVED
# products, and BEFORE the order_id shape check because an un-attested agent
# should be told to go and get attested rather than told its id is malformed.
# Both orderings are published behaviour and neither is this conversion's to
# change.
class CreateOrderOperation
  # The anonymized booleans this verb demands of an age-restricted cart. Named
  # once, so the gate, the refusal sentence and the hint cannot come to disagree
  # about what is required — getgrocery asks the broker for exactly this ONE
  # claim and deliberately not for a driving licence.
  REQUIRED_KYC_ATTRIBUTES = %w[age_over_18].freeze

  # @param principal_id [String] the account the wire resolved. NEVER an
  #   argument off the request: create_order deliberately IGNORES a forged
  #   `user_id` in the body, and it can do that precisely because the value is
  #   passed in from the identity rather than read out of the params.
  #
  #   An INSERT is the one place the principal must be spelled in Ruby. Every
  #   READ scopes with `Order.owned_by_current_principal`, which never names the
  #   principal at all because a WHERE has a predicate to hide it in; an INSERT
  #   has no predicate, so it must supply the value. Both are un-forgeable for
  #   the same reason — the identity is resolved from the Rack env the wire
  #   built, which no request argument can write — but only the first keeps the
  #   database as the authority. Moving the column DEFAULT to
  #   `kiosk.current_user_id()` would close the gap; that is a migration, not
  #   part of a handler conversion.
  # @param items [Object] the raw cart, already unwrapped from
  #   ActionController::Parameters by the controller — its ELEMENT TYPE is a
  #   decision gate 1 makes, so it may not arrive as a controller type.
  def self.call(principal_id:, items:, delivery_slot_id:, delivery_date:, delivery_address:, order_id:)
    # ── Gate 1: the cart ───────────────────────────────────────────────────
    items, refusal = WireArguments.items(items)
    return refusal if refusal

    # ── Gate 2: delivery is part of the order ──────────────────────────────
    # Presence of BOTH fields first, then the zone, then the window's range —
    # the raw handler's order, kept because it decides which of two wrong
    # arguments a caller hears about first.
    return WireArguments.missing("delivery_slot_id — delivery is part of the order") if delivery_slot_id.nil?
    return WireArguments.missing("delivery_address — delivery is part of the order") if delivery_address.blank?

    _zone, refusal = WireArguments.served_zone(delivery_address)
    return refusal if refusal

    slot_id, refusal = WireArguments.delivery_slot_id(delivery_slot_id)
    return refusal if refusal

    # ── Gate 3: the window, on the day the assistant saw it (K-470) ────────
    # Backward-compat: an omitted delivery_date falls back to tomorrow (the
    # historical default) so callers that pre-date the field still work — but a
    # caller that saw a slot for a specific day SHOULD pass that day back.
    date, refusal = WireArguments.delivery_date(
      delivery_date,
      default:      Date.today + 1,
      past_message: ->(d) { "delivery_date is in the past: #{d} — choose a current/future delivery slot" },
    )
    return refusal if refusal

    slot_at = DeliverySlots.slot_at(date, slot_id)
    refusal = WireArguments.past_slot(
      date, slot_id,
      "choose a later slot; call delivery_slots again for the still-bookable windows",
    )
    return refusal if refusal

    # The whole write is ONE transaction, as it was: the replace path reads a row
    # under a lock and then rewrites its items, and those must not be separable.
    # It joins the SessionContext transaction the wire already opened (that is
    # where the GUCs `owned_by_current_principal` reads are SET LOCAL), so this
    # is a statement about what belongs together rather than a second unit of
    # atomicity. `next` and never `return`: a non-local exit out of a transaction
    # block is a thing to reason about, and there is nothing here that needs one.
    ApplicationRecord.transaction do
      # ── Gate 4: every sku exists ─────────────────────────────────────────
      # Deliberately NOT `Product.in_stock`: the catalogue HIDES an out-of-stock
      # line, but an order naming one is a stock question, not an unknown-sku
      # one, and answering it here would be a behaviour change.
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
      # KYC-DEMO-SCOPE (b): anonymized minimal KYC belongs on a LOW-liability
      # eligibility gate where the transaction closes (an alcohol PURCHASE), not
      # on high-liability rental. If the cart contains ANY age_restricted
      # product, the authenticated agent must carry an engine-verified
      # age_over_18 attestation. Only booleans a valid, broker-signed attestation
      # granted are ever persisted in `kyc_attributes` — a forged or
      # self-asserted claim never reaches that column, because POST
      # /kiosk/agents/kyc rejects a bad signature. A cart with no restricted item
      # skips this entirely. {Product.age_restricted?} reads the flag fail-closed
      # and {Agent.kyc_granted?} keeps the `->>` extraction in Postgres; the
      # comments there are the load-bearing half of this gate.
      restricted = items.any? { |item| Product.age_restricted?(by_sku[item[:sku]][:age_restricted]) }
      if restricted && !Agent.kyc_granted?(*REQUIRED_KYC_ATTRIBUTES)
        next OperationResult.refused(
          code:    "kyc_required",
          message: "this cart contains an age-restricted (alcohol) item — an 18+ verification " \
                   "is required to order it",
          # Point an external agent at the completable path, in the spelling
          # the 0.4 wire actually uses: POST <endpoint>/request_kyc returns a
          # verification_url the human approves, then GET <endpoint>/kyc_status
          # carries the signed attestation, which is submitted to
          # POST <endpoint>/agents/kyc — no pre-shared issuer key needed.
          hint:    "POST <endpoint>/request_kyc to start an 18+ (age_over_18) verification: " \
                   "it returns a verification_url for the human to approve; then poll " \
                   "GET <endpoint>/kyc_status for the signed attestation and submit it to " \
                   "POST <endpoint>/agents/kyc, then retry create_order",
        )
      end

      total_cents = items.sum { |item| by_sku[item[:sku]][:price_cents].to_i * item[:qty] }
      # The timestamps were `now()` — the DATABASE clock — and are the app clock
      # now, because `insert_all`/`update_all` type-cast their values and have no
      # way to pass an SQL expression through. `my_orders` orders by
      # `created_at`, and app and database run on one host in every demo and on
      # the deployed box, so the two clocks are the same clock.
      now = Time.current

      replaced = nil
      if order_id.present?
        # K-579: this id used to be cast `::uuid`, and a malformed one made
        # Postgres raise InvalidTextRepresentation — a raw 500 for a plain client
        # mistake. Under ActiveRecord the failure would be quieter and worse: an
        # unparseable uuid is CAST TO NULL, matches nothing, and the caller would
        # be told its order is not replaceable rather than that its id is not an
        # id. ActiveRecord does not refuse junk, it casts it.
        order_id, refusal = WireArguments.order_id(order_id, hint: WireArguments::HINT_ORDER_ID_REPLACE)
        next refusal if refusal

        # ── Gate 6: replaceable, AND held while we replace it (K-544) ──────
        # Two conditions and one lock, and all three ARE the pay-race fix:
        #   · `replaceable` excludes `paying` as well as the terminal states — a
        #     /pay for this order is mid-flight and its cart has already been
        #     checked against these items, so swapping them now is "pay for the
        #     cheap basket, receive the expensive one";
        #   · the NOT EXISTS refuses an order some settled cart already
        #     references, whatever its local status says;
        #   · `lock` is `FOR UPDATE` on the orders row, which serializes this
        #     replace against the pay path's atomic `created → paying` claim.
        # Together they make "replace items" and "begin paying" mutually
        # exclusive on one order row. The containment is
        # {CartMandate.referencing} — the same predicate the pay path and the
        # operator's back office read, written once.
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

      # `insert!` and NOT `create!`, deliberately, and the reason is a wire
      # answer rather than taste. `create!` interposes validations, so
      # `belongs_to :user` (required by default) would turn a principal with no
      # `users` row from the `ActiveRecord::InvalidForeignKey` Postgres raises —
      # unmapped in `rescue_responses`, so re-raised and wrapped
      # `action_failed`/500, which is what the raw INSERT did — into a
      # `RecordInvalid`, which Rails maps to 422 and the handler mixin's floor
      # renders as a 400. A 500 silently becoming a 400 for an unrelated input is
      # exactly the class of change this conversion must not make. Measured on
      # THIS model, not assumed.
      #
      # The `id` is not supplied here at all any more: the raw INSERT wrote
      # `gen_random_uuid()` from the handler, and id generation belongs to the
      # column DEFAULT — which is that same function — rather than to a
      # caller-facing verb (K-654's third charge).
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

      # One statement for the whole cart where the raw handler wrote one per
      # line. `insert_all!` and not `insert_all`, so a product row that vanished
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
