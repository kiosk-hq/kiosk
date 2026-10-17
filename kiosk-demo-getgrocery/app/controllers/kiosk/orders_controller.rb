# frozen_string_literal: true

# The customer's orders: placing and reading them. The work is in app/operations.
module Kiosk
  class OrdersController < ActionController::API
    include Kiosk::Handler

    ORDER_ID = 'e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e'

    kind :query
    description "The signed-in customer's orders, with their delivery window and where the money " \
                'stands. Re-read it after a payment whose answer never arrived.'
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  description: 'Orders, newest first.',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      order_id: { type: 'string' },
                      status: { type: 'string', enum: Order.statuses.keys,
                                description: 'Where the basket stands.' },
                      total_cents: { type: 'integer', description: 'EUR cents.' },
                      slot_at: { type: 'string', description: "The delivery window's start." },
                      slot_label: { type: 'string', description: 'The window as a human reads it.' },
                      address: { type: 'string' },
                      payment_state: { type: 'string', enum: %w[unpaid pending paid],
                                       description: '`pending`: a charge is under way, so wait and ' \
                                                    'read again. Pay again only on `unpaid`.' }
                    },
                    required: %w[order_id status total_cents slot_at slot_label address payment_state]
                  }
    def my_orders
      @orders = Order.own.with_settlement(Kiosk::Settlement.own).order(created_at: :desc)
    end

    kind :action
    description 'Place an order for delivery in a window at an address. The answer carries the ' \
                'quote to pay. Alcohol needs a completed 18+ check (`request_kyc`); a cart is at ' \
                "most #{Order::MAX_ITEMS} lines of at most #{OrderItem::MAX_QTY} each."
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   items: {
                     type: 'array', minItems: 1, maxItems: Order::MAX_ITEMS,
                     items: {
                       type: 'object', additionalProperties: false,
                       properties: {
                         sku: { type: 'string', description: 'A catalog sku.' },
                         qty: { type: 'integer', minimum: 1, maximum: OrderItem::MAX_QTY }
                       },
                       required: %w[sku qty]
                     }
                   },
                   slot_at: { type: 'string', format: 'date-time',
                              description: 'The `slot_at` of a delivery_slots row.' },
                   delivery_address: { type: 'string', description: 'The address delivery_slots was asked about.' }
                 },
                 required: %w[items slot_at delivery_address]
    output_schema type: 'object',
                  description: 'The order, priced.',
                  additionalProperties: false,
                  properties: {
                    order_id: { type: 'string', description: 'Put it in the cart you sign, as `pay_hint` says.' },
                    total_cents: { type: 'integer', description: 'EUR cents; sign the cart at exactly this total.' },
                    total_eur: { type: 'string', description: 'The total as a human reads it.' },
                    currency: { type: 'string' },
                    slot_at: { type: 'string', description: "The delivery window's start." },
                    slot_label: { type: 'string', description: 'The window as a human reads it.' },
                    timezone: { type: 'string', description: "The delivery address's IANA zone." },
                    pay_hint: { type: 'string', description: 'How to pay for this order.' }
                  },
                  required: %w[order_id total_cents total_eur currency slot_at slot_label timezone pay_hint]
    example_params({
                     items: [{ sku: 'sourdough-bread', qty: 2 }, { sku: 'greek-yogurt', qty: 1 }],
                     slot_at: -> { DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2].iso8601 },
                     delivery_address: '42 Camden Street, Dublin 2'
                   })
    example_row({
                  order_id: ORDER_ID, total_cents: 1287, total_eur: '€12.87', currency: 'eur',
                  slot_at: -> { DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2].iso8601 },
                  slot_label: "12:00–14:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})",
                  timezone: DeliverySlots::DEFAULT_ZONE_NAME,
                  pay_hint: 'Call `pay` in EUR with a cart mandate (a signed cart) for exactly this order …'
                })
    def create_order
      @order = CreateOrderOperation.call(
        customer_id: kiosk_identity.user_id,
        items: params[:items].map { it.permit(:sku, :qty).to_h.symbolize_keys },
        slot_at: params[:slot_at],
        delivery_address: params[:delivery_address]
      )
    end
  end
end
