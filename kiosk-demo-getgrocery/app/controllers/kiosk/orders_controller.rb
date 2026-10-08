# frozen_string_literal: true

# The write verbs. The work is in app/operations.

class Kiosk::OrdersController < ActionController::API
  include Kiosk::Handler

  topic :order_payment do
    description "An order of yours settled. Its delivery is now scheduled and " \
                "reschedule_delivery will accept it."
    payload_schema type: "object", additionalProperties: false,
                   properties: { order_id:      { type: "string", format: "uuid" },
                                 payment_state: { enum: %w[paid] } },
                   required: %w[order_id payment_state]
    subject_reachable ->(order_id, identity) { Order.readable_by?(order_id, identity.user_id) }
  end

  topic :order_delivery do
    description "Your order is on its way, or has arrived. `out_for_delivery` carries the ETA — " \
                "the delivery window this order was booked for, with the clock it was quoted " \
                "on — and `delivered` means it is at the door. Nothing to call back: this is " \
                "the shop acting, not an answer to a request of yours."
    payload_schema type: "object", additionalProperties: false,
                   properties: { order_id:  { type: "string", format: "uuid" },
                                 status:    { enum: %w[out_for_delivery delivered] },
                                 eta:       { type: "string", format: "date-time",
                                              description: "When the window opens. Present on " \
                                                           "`out_for_delivery` only." },
                                 eta_label: { type: "string",
                                              description: "The same window as a human reads " \
                                                           "it, on the clock below." },
                                 timezone:  { type: "string",
                                              description: "The delivery district's clock — the " \
                                                           "one `eta_label` is written on." } },
                   required: %w[order_id status]
    subject_reachable ->(order_id, identity) { Order.readable_by?(order_id, identity.user_id) }
  end

  kind :action
  description "Create a grocery order for the authenticated principal. It does ONE thing — it " \
              "places an order — and it takes no existing order to amend: a human who changes " \
              "their mind before any money moves gets a NEW order, with every parameter fresh, " \
              "and the one nobody pays for is simply never delivered and never charged. Delivery is " \
              "part of the order rather than a later step: this origin will not take an order it " \
              "cannot deliver, so a window and an address are required to place one. The answer " \
              "carries the operator's quote and, in words, the exact mandate that quote expects — " \
              "sign your AP2 cart against it, in this operator's currency, mirroring the order line " \
              "for line at catalogue prices and naming the order itself. The cashier re-counts every " \
              "line against its own catalogue before it charges anything, so a cart that disagrees is " \
              "refused outright rather than partly honoured. Alcohol needs a completed 18+ check " \
              "first (`request_kyc`), and asking for it without one is refused rather than quietly " \
              "dropped from the basket. A cart whose catalogue total is larger than this " \
              "operator can put on one order is refused outright, naming the maximum, rather " \
              "than partly taken."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 items: {
                   type: "array", minItems: 1,
                   description: "The complete cart — products referenced by sku.",
                   items: {
                     type: "object", additionalProperties: false,
                     properties: {
                       sku: { type: "string", description: "Product sku from the catalog query." },
                       qty: { type: "integer", minimum: 1, maximum: WireArguments::MAX_INT4,
                              description: "Quantity. The order's total — each line's catalogue " \
                                           "price times its qty, summed — is bounded too; a cart " \
                                           "too large to price is refused, not partly taken." },
                     },
                     required: ["sku", "qty"],
                   },
                 },
                 delivery_slot_id: { type: "integer", minimum: 1, maximum: 6,
                                     description: "The `delivery_slot_id` from a delivery_slots row (1..6)." },
                 delivery_date:    { type: "string", format: "date",
                                     description: "The `date` (YYYY-MM-DD) of the chosen delivery_slots row, so the booking lands on the day you saw. It ECHOES that row, so it is read on the clock the row was published on — the delivery address's — and NOT in your own calendar; that way the day you were offered is the day you get." },
                 delivery_address: { type: "string",
                                     description: "In-zone Dublin delivery address naming a served postal district (e.g. \"Dublin 2\" / \"D02\")." },
               },
               required: ["items", "delivery_slot_id", "delivery_date", "delivery_address"]
  output_schema type: "object",
                description: "The created order, priced.",
                additionalProperties: false,
                properties: {
                  order_id:    { type: "string", description: "uuid. Name it in the cart mandate's `order_id` line item, and pass it to reschedule_delivery as `order_id`." },
                  total_cents: { type: "integer", description: "EUR cents. Sign the cart at exactly this total." },
                  total_eur:   { type: "string", description: "The same total rendered for a human, e.g. \"€12.87\"." },
                  currency:    { type: "string", description: "eur — the currency the cart must be signed in." },
                  slot_at:     { type: "string", description: "The booked delivery window's start instant, ISO 8601 with offset." },
                  slot_label:  { type: "string", description: "The booked window rendered for a human, IN THE ZONE IT NAMES — " \
                                                              "e.g. \"08:00–10:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})\". The wall clock " \
                                                              "is the delivery address's, not the caller's; `slot_at` carries " \
                                                              "the same instant with its resolved offset." },
                  timezone:    { type: "string", description: "The IANA zone this window is written in — a property of the DELIVERY ADDRESS, not of this shop." },
                  pay_hint:    { type: "string", description: "The mandate this order expects, in words." },
                },
                required: %w[order_id total_cents total_eur currency slot_at slot_label timezone pay_hint]
  example_params({
    items: [{ sku: "sourdough-bread", qty: 2 }, { sku: "greek-yogurt", qty: 1 }],
    delivery_slot_id: 3,
    delivery_date:    -> { DeliverySlots.example_date.iso8601 },
    delivery_address: "42 Camden Street, Dublin 2",
  })
  example_row({
    order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e", total_cents: 1287,
    total_eur: "€12.87", currency: "eur",
    slot_at: -> { DeliverySlots.slot_at(DeliverySlots.example_date, 3).iso8601 },
    slot_label: -> { DeliverySlots.label(DeliverySlots.slot_at(DeliverySlots.example_date, 3)) },
    timezone: DeliverySlots::DEFAULT_ZONE_NAME,
    pay_hint: "pay in EUR with a cart mandate whose line_items mirror this order …",
  })
  def create_order
    render json: CreateOrderOperation.call(
      principal_id:     kiosk_identity.user_id,
      items:            params[:items].map { _1.permit(:sku, :qty).to_h.symbolize_keys },
      delivery_slot_id: params[:delivery_slot_id].to_i,
      delivery_date:    params[:delivery_date],
      delivery_address: params[:delivery_address],
    )
  end

  kind :action
  description "Move an ALREADY-PAID order's delivery to a different window, and optionally to a " \
              "different address. It REUSES the payment already on that order: there is no new " \
              "mandate to sign, nothing new to settle, and no second charge — call it directly, and " \
              "note that re-paying an order that is already settled is refused (403). «Already paid» " \
              "is a PRECONDITION, not an instruction to settle now: an order nobody has paid for " \
              "cannot be rescheduled at all — place the order you want with `create_order`, which " \
              "stays free until it is paid. One reschedule per order — anything further goes " \
              "through the operator."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 order_id:         { type: "string", format: "uuid",
                                     pattern: Kiosk::UuidCheck::JSON_SCHEMA_PATTERN,
                                     description: "uuid of the ALREADY-PAID order to reschedule. Its existing payment is reused — do not pay again." },
                 delivery_slot_id: { type: "integer", minimum: 1, maximum: 6,
                                     description: "The new `delivery_slot_id` from a delivery_slots row (1..6)." },
                 delivery_date:    { type: "string", format: "date",
                                     description: "The `date` (YYYY-MM-DD) of the chosen delivery_slots row. It ECHOES that row, so it is read on the clock the row was published on — the delivery address's — and NOT in your own calendar." },
                 delivery_address: { type: "string",
                                     description: "New in-zone Dublin delivery address; unchanged if omitted." },
               },
               required: ["order_id", "delivery_slot_id", "delivery_date"]
  output_schema type: "object",
                description: "The rescheduled order.",
                additionalProperties: false,
                properties: {
                  order_id:       { type: "string", description: "The order that moved, echoed." },
                  rescheduled_at: { type: "string", description: "The NEW delivery window's start instant, ISO 8601 with offset." },
                  rescheduled_label: { type: "string", description: "The NEW window rendered for a human, IN THE ZONE IT NAMES — " \
                                                                    "e.g. \"08:00–10:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})\" — from the same " \
                                                                    "writer as `delivery_slots`, `create_order` and `my_orders`." },
                  timezone:       { type: "string", description: "The IANA zone the new window is written in — a property of the DELIVERY ADDRESS the order lands at." },
                },
                required: %w[order_id rescheduled_at rescheduled_label timezone]
  example_params({ order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e", delivery_slot_id: 3,
                   delivery_date: -> { DeliverySlots.example_date.iso8601 } })
  example_row({ order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e",
                rescheduled_at: -> { DeliverySlots.slot_at(DeliverySlots.example_date, 3).iso8601 },
                rescheduled_label: -> { DeliverySlots.label(DeliverySlots.slot_at(DeliverySlots.example_date, 3)) },
                timezone: DeliverySlots::DEFAULT_ZONE_NAME })
  def reschedule_delivery
    render json: RescheduleDeliveryOperation.call(
      order_id:         params[:order_id],
      delivery_slot_id: params[:delivery_slot_id].to_i,
      delivery_date:    params[:delivery_date],
      delivery_address: params[:delivery_address],
    )
  end
end
