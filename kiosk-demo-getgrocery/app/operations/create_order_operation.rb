# frozen_string_literal: true

# create_order — place one grocery order for the authenticated principal, with
# its delivery window and address, and quote the total a cart mandate must be
# signed against.
#
# It places an order and does nothing else. There is no amend path and no
# argument naming an existing order: a change of mind before any money moves is
# a fresh call with the parameters the human now wants, and the unpaid row left
# behind is never delivered and never charged.
#
# SIX GATES, in the order they are written below, and the order is behaviour
# rather than tidiness — each one is the answer a caller gets when a later one
# would also have refused: the cart's shape, delivery given and in-zone, the
# window still bookable, the skus, the age gate, the priceable total. Gate 5
# comes AFTER the sku resolution because it is a fact about the RESOLVED
# products. Gate 6 can only be asked once gate 4 has resolved the prices — it
# bounds their SUM — and it is asked before anything is written.
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
  def self.call(principal_id:, items:, delivery_slot_id:, delivery_date:, delivery_address:)
    # ── Gate 1: the cart ───────────────────────────────────────────────────
    items, refusal = WireArguments.items(items)
    return refusal if refusal

    # ── Gate 2: delivery is part of the order ──────────────────────────────
    # Presence of BOTH fields first, then the zone, then the window's range: the
    # sequence decides which of two wrong arguments a caller hears about first.
    return WireArguments.missing("delivery_slot_id — delivery is part of the order") if delivery_slot_id.nil?
    return WireArguments.missing("delivery_address — delivery is part of the order") if delivery_address.blank?

    district, refusal = WireArguments.served_district(delivery_address)
    return refusal if refusal

    # THE CLOCK IS THE DELIVERY ADDRESS's — the door is where the service
    # happens — read off the district it just routed to and not off this origin.
    zone = DeliverySlots.zone_for(district)

    slot_id, refusal = WireArguments.delivery_slot_id(delivery_slot_id)
    return refusal if refusal

    # ── Gate 3: the window, on the day the assistant saw it ────────────────
    # An omitted delivery_date falls back to tomorrow, for callers that pre-date
    # the field — but a caller that saw a slot for a day SHOULD pass that day.
    date, refusal = WireArguments.delivery_date(
      delivery_date,
      default:      DeliverySlots.now(zone).to_date + 1,
      past_message: ->(d) { "delivery_date is in the past: #{d} — choose a current/future delivery slot" },
      zone:         zone,
    )
    return refusal if refusal

    slot_at = DeliverySlots.slot_at(date, slot_id, zone)
    refusal = WireArguments.past_slot(
      date, slot_id,
      "choose a later slot; call delivery_slots again for the still-bookable windows",
      zone,
    )
    return refusal if refusal

    # ONE transaction: the order row and its items are written together or not
    # at all. It joins the SessionContext transaction the wire already opened
    # (where the GUCs `owned_by_current_principal` reads are SET LOCAL), so it
    # states what belongs together rather than opening a second unit of
    # atomicity. `next` and never `return`: nothing here needs a non-local exit
    # out of the block.
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

      # ── Gate 6: the cart has to be PRICEABLE ─────────────────────────────
      # Every `qty` here is one the published descriptor calls valid, and the
      # SUM is still bounded by `orders.total_cents`. Without this the INSERT
      # below raises `ActiveModel::RangeError` in Ruby and the wire answers
      # `500 action_failed` for an argument a client simply got wrong.
      refusal = WireArguments.priceable_total(total_cents)
      next refusal if refusal

      # The APP clock, not `now()`: `insert_all` type-casts its values and
      # cannot pass an SQL expression through. App and database run on one host
      # here, so it is the same clock `my_orders` then orders by.
      now = Time.current

      # `insert!` and NOT `create!`, and the reason is a wire answer rather than
      # taste: `create!` interposes validations, so `belongs_to :user` would turn
      # a principal with no `users` row from the `InvalidForeignKey` Postgres
      # raises — unmapped in `rescue_responses`, so a 500 — into a
      # `RecordInvalid`, which Rails maps to 422 and the mixin's floor renders as
      # a 400. No `id` is supplied either: generating it belongs to the column
      # DEFAULT (`gen_random_uuid()`), not to a caller-facing verb.
      new_order_id = Order.insert!(
        { user_id:     principal_id,
          status:      Order::CREATED,
          total_cents: total_cents,
          slot_at:     slot_at,
          address:     delivery_address.to_s,
          # The zone the window above was computed in, stored as a fact of the
          # order rather than re-derived from `address` by every later reader.
          # `slot_at` is an instant and an instant alone cannot say which wall
          # clock it was spoken as; this column is that half of the answer.
          timezone:    zone.name,
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
        # ONE FIELD, ONE CLOCK, EVERY VERB — and the label travels with it.
        # `delivery_slots` offered this window with a zone-bearing label beside
        # it; the booking answers with the same string from the same writer, so
        # an assistant reading the confirmation back to a human speaks the
        # window in the delivery zone rather than in an offset nobody says out
        # loud.
        slot_label:  DeliverySlots.label(slot_at, zone),
        timezone:    zone.name,
        pay_hint:    "pay in EUR with a cart mandate whose line_items mirror this order: " \
                     "one {\"order_id\": \"#{new_order_id}\"} entry plus one " \
                     "{\"sku\", \"qty\", \"price_cents\"} entry per item at catalog prices — " \
                     "the operator verifies currency, prices, and total before charging",
      })
    end
  end
end
