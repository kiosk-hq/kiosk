# frozen_string_literal: true

# The delivery windows at an address.
module Kiosk
  class DeliverySlotsController < ActionController::API
    include Kiosk::Handler

    kind :query
    description 'The delivery windows still bookable on a day at a Dublin address in a served ' \
                'district. Ask the customer for their real address first; an empty answer means ' \
                'that day is full, so try a later one.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   date: { type: 'string', format: 'date',
                           description: "A day on the delivery address's clock. Omit it " \
                                        'for the soonest day the shop delivers.' },
                   delivery_address: { type: 'string', description: 'A Dublin address naming its postal district, e.g. "Dublin 2".' }
                 },
                 required: ['delivery_address']
    output_schema type: 'array',
                  description: 'Bookable windows, earliest first.',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      slot_at: { type: 'string', description: "The window's start; pass it to create_order." },
                      label: { type: 'string', description: 'The window as a human reads it, e.g. ' \
                                                            "\"08:00–10:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})\"." },
                      timezone: { type: 'string', description: "The delivery address's IANA zone." },
                      district: { type: 'string', description: 'The postal district the address routed to, e.g. "D02".' }
                    },
                    required: %w[slot_at label timezone district]
                  }
    example_params({ date: -> { DeliverySlots.default_zone.tomorrow.iso8601 },
                     delivery_address: '42 Camden Street, Dublin 2' })
    example_row({ slot_at: -> { DeliverySlots.starts(DeliverySlots.default_zone.tomorrow).first.iso8601 },
                  label: "08:00–10:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})",
                  timezone: DeliverySlots::DEFAULT_ZONE_NAME, district: 'D02' })
    def delivery_slots
      @search = SlotSearch.new(delivery_address: params[:delivery_address], date: params[:date])
      @search.validate!
    end
  end
end
