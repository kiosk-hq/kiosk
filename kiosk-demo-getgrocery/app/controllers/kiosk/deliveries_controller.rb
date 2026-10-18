# frozen_string_literal: true

# An order's delivery: moving it to another window, and following the courier. The work is in app/operations.
module Kiosk
  class DeliveriesController < ActionController::API
    include Kiosk::Handler

    eta = DeliverySlots.starts(DeliverySlots.default_zone.tomorrow).first + 40.minutes

    topic :order_delivery do
      description "The order is on its way (`out_for_delivery`, with the courier's ETA), at the " \
                  'door (`delivered`), or `cancelled`: everything in it sold out before it was packed, and the ' \
                  'payment went back to the card.'
      payload_schema type: 'object', additionalProperties: false,
                     properties: { order_id: { type: 'string', format: 'uuid' },
                                   status: { enum: %w[out_for_delivery delivered cancelled] },
                                   eta: { type: 'string', format: 'date-time',
                                          description: 'When the courier arrives.' },
                                   eta_label: { type: 'string', description: 'The ETA as a human reads it.' },
                                   timezone: { type: 'string', description: "The delivery address's IANA zone." } },
                     required: %w[order_id status]
      example order_id: OrdersController::ORDER_ID, status: 'out_for_delivery', eta: eta.utc.iso8601,
              eta_label: DeliverySlots.clock_label(eta, DeliverySlots.default_zone),
              timezone: DeliverySlots::DEFAULT_ZONE_NAME
      example order_id: OrdersController::ORDER_ID, status: 'delivered'
      example order_id: OrdersController::ORDER_ID, status: 'cancelled'
      subject_reachable ->(order_id, identity) { Order.readable_by?(order_id, identity.user_id) }
    end

    kind :action
    description 'Move a paid order to another delivery window, optionally to another address. The ' \
                'payment already made covers it. Once per order.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   order_id: { type: 'string', format: 'uuid' },
                   slot_at: { type: 'string', format: 'date-time',
                              description: 'The `slot_at` of a delivery_slots row.' },
                   delivery_address: { type: 'string', description: "The new address; the order's own if omitted." }
                 },
                 required: %w[order_id slot_at]
    output_schema type: 'object',
                  description: 'The moved order.',
                  additionalProperties: false,
                  properties: {
                    order_id: { type: 'string' },
                    rescheduled_at: { type: 'string', description: "The new window's start." },
                    rescheduled_label: { type: 'string', description: 'The new window as a human reads it.' },
                    timezone: { type: 'string', description: "The delivery address's IANA zone." }
                  },
                  required: %w[order_id rescheduled_at rescheduled_label timezone]
    example_params({ order_id: OrdersController::ORDER_ID,
                     slot_at: -> { DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2].iso8601 } })
    example_row({ order_id: OrdersController::ORDER_ID,
                  rescheduled_at: -> { DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2].iso8601 },
                  rescheduled_label: "12:00–14:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})",
                  timezone: DeliverySlots::DEFAULT_ZONE_NAME })
    def reschedule_delivery
      @order = RescheduleDeliveryOperation.call(
        order_id: params[:order_id],
        slot_at: params[:slot_at],
        delivery_address: params[:delivery_address]
      )
    end
  end
end
