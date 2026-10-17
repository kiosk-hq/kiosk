# frozen_string_literal: true

# The customer's orders: placing, moving and following them. The work is in app/operations.
class Kiosk::OrdersController < ActionController::API
  include Kiosk::Handler

  ORDER_ID = "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e"

  topic :order_payment do
    description "An order of yours is paid; its delivery is scheduled."
    payload_schema type: "object", additionalProperties: false,
                   properties: { order_id:      { type: "string", format: "uuid" },
                                 payment_state: { enum: %w[paid] } },
                   required: %w[order_id payment_state]
    example order_id: ORDER_ID, payment_state: "paid"
    subject_reachable ->(order_id, identity) { Order.readable_by?(order_id, identity.user_id) }
  end

  topic :order_delivery do
    description "The order is on its way (`out_for_delivery`, with the courier's ETA) or at the " \
                "door (`delivered`)."
    payload_schema type: "object", additionalProperties: false,
                   properties: { order_id:  { type: "string", format: "uuid" },
                                 status:    { enum: %w[out_for_delivery delivered] },
                                 eta:       { type: "string", format: "date-time",
                                              description: "When the courier arrives." },
                                 eta_label: { type: "string", description: "The ETA as a human reads it." },
                                 timezone:  { type: "string", description: "The delivery address's IANA zone." } },
                   required: %w[order_id status]
    example order_id: ORDER_ID, status: "out_for_delivery", eta: "2026-10-18T09:40:00Z",
            eta_label: "10:40 (Europe/Dublin)", timezone: "Europe/Dublin"
    example order_id: ORDER_ID, status: "delivered"
    subject_reachable ->(order_id, identity) { Order.readable_by?(order_id, identity.user_id) }
  end

  kind :query
  description "The signed-in customer's orders, with their delivery window and where the money " \
              "stands. Re-read it after a payment whose answer never arrived."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "Orders, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    order_id:      { type: "string" },
                    status:        { type: "string", enum: Order.statuses.keys,
                                     description: "Where the basket stands." },
                    total_cents:   { type: "integer", description: "EUR cents." },
                    slot_at:       { type: "string", description: "The delivery window's start." },
                    slot_label:    { type: "string", description: "The window as a human reads it." },
                    address:       { type: "string" },
                    payment_state: { type: "string", enum: %w[unpaid pending paid],
                                     description: "`pending`: a charge is under way, so wait and " \
                                                  "re-read. Only `unpaid` calls for a new mandate." },
                  },
                  required: %w[order_id status total_cents slot_at slot_label address payment_state],
                }
  def my_orders
    render json: Order.own.with_settlement(Kiosk::Settlement.own).order(created_at: :desc).map { |order|
      { "order_id"      => order.id,
        "status"        => order.status,
        "total_cents"   => order.total_cents,
        "slot_at"       => order.slot_at.in_time_zone(order.zone).iso8601,
        "slot_label"    => DeliverySlots.label(order.slot_at, order.zone),
        "address"       => order.address,
        "payment_state" => order.payment_state }
    }
  end

  kind :action
  description "Place an order for delivery in a window at an address. The answer carries the " \
              "quote to pay. Alcohol needs a completed 18+ check (`request_kyc`); a cart is at " \
              "most #{Order::MAX_ITEMS} lines of at most #{OrderItem::MAX_QTY} each."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 items: {
                   type: "array", minItems: 1, maxItems: Order::MAX_ITEMS,
                   items: {
                     type: "object", additionalProperties: false,
                     properties: {
                       sku: { type: "string", description: "A catalog sku." },
                       qty: { type: "integer", minimum: 1, maximum: OrderItem::MAX_QTY },
                     },
                     required: ["sku", "qty"],
                   },
                 },
                 slot_at:          { type: "string", format: "date-time",
                                     description: "The `slot_at` of a delivery_slots row." },
                 delivery_address: { type: "string", description: "The address delivery_slots was asked about." },
               },
               required: ["items", "slot_at", "delivery_address"]
  output_schema type: "object",
                description: "The order, priced.",
                additionalProperties: false,
                properties: {
                  order_id:    { type: "string", description: "Name it in the cart mandate." },
                  total_cents: { type: "integer", description: "EUR cents; sign the cart at exactly this total." },
                  total_eur:   { type: "string", description: "The total as a human reads it." },
                  currency:    { type: "string" },
                  slot_at:     { type: "string", description: "The delivery window's start." },
                  slot_label:  { type: "string", description: "The window as a human reads it." },
                  timezone:    { type: "string", description: "The delivery address's IANA zone." },
                  pay_hint:    { type: "string", description: "The cart mandate this order expects." },
                },
                required: %w[order_id total_cents total_eur currency slot_at slot_label timezone pay_hint]
  example_params({
    items: [{ sku: "sourdough-bread", qty: 2 }, { sku: "greek-yogurt", qty: 1 }],
    slot_at:          -> { DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2].iso8601 },
    delivery_address: "42 Camden Street, Dublin 2",
  })
  example_row({
    order_id: ORDER_ID, total_cents: 1287, total_eur: "€12.87", currency: "eur",
    slot_at: -> { DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2].iso8601 },
    slot_label: "12:00–14:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})",
    timezone: DeliverySlots::DEFAULT_ZONE_NAME,
    pay_hint: "pay in EUR with a cart mandate whose line_items mirror this order …",
  })
  def create_order
    render json: CreateOrderOperation.call(
      customer_id:      kiosk_identity.user_id,
      items:            params[:items].map { _1.permit(:sku, :qty).to_h.symbolize_keys },
      slot_at:          params[:slot_at],
      delivery_address: params[:delivery_address],
    )
  end

  kind :action
  description "Move a paid order to another delivery window, optionally to another address. The " \
              "payment already made covers it. Once per order."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 order_id:         { type: "string", format: "uuid",
                                     pattern: Kiosk::UuidCheck::JSON_SCHEMA_PATTERN },
                 slot_at:          { type: "string", format: "date-time",
                                     description: "The `slot_at` of a delivery_slots row." },
                 delivery_address: { type: "string", description: "The new address; the order's own if omitted." },
               },
               required: ["order_id", "slot_at"]
  output_schema type: "object",
                description: "The moved order.",
                additionalProperties: false,
                properties: {
                  order_id:          { type: "string" },
                  rescheduled_at:    { type: "string", description: "The new window's start." },
                  rescheduled_label: { type: "string", description: "The new window as a human reads it." },
                  timezone:          { type: "string", description: "The delivery address's IANA zone." },
                },
                required: %w[order_id rescheduled_at rescheduled_label timezone]
  example_params({ order_id: ORDER_ID,
                   slot_at:  -> { DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2].iso8601 } })
  example_row({ order_id: ORDER_ID,
                rescheduled_at: -> { DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2].iso8601 },
                rescheduled_label: "12:00–14:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})",
                timezone: DeliverySlots::DEFAULT_ZONE_NAME })
  def reschedule_delivery
    render json: RescheduleDeliveryOperation.call(
      order_id:         params[:order_id],
      slot_at:          params[:slot_at],
      delivery_address: params[:delivery_address],
    )
  end
end
