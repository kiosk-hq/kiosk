# frozen_string_literal: true

# The hotel's answer to a paid booking.

module Kiosk
  class ConfirmationsController < ActionController::API
    include Kiosk::Handler

    topic :booking_confirmation do
      description 'The hotel answered a paid booking: `confirmed`, with the code the guest gives at the desk, ' \
                  'or `cancelled`, with the refund to the card that paid.'
      payload_schema type: 'object', additionalProperties: false,
                     properties: { booking_id: { type: 'string', format: 'uuid' },
                                   status: { enum: %w[confirmed cancelled] },
                                   confirmation_code: { type: 'string' },
                                   reason: { type: 'string' },
                                   refund: { type: 'object', additionalProperties: false,
                                             properties: {
                                               amount_cents: { type: 'integer' },
                                               currency: { type: 'string' },
                                               psp_reference: { type: 'string' },
                                               reverses: { type: 'string',
                                                           description: 'The charge this refund reverses.' }
                                             } } },
                     required: %w[booking_id status]
      example booking_id: BookingsController::BOOKING_ID, status: 'confirmed', confirmation_code: '5d1c9e04-8f2b-4a6e-b3c7-2e9f0a4d6b18'
      example booking_id: BookingsController::BOOKING_ID, status: 'cancelled', reason: 'property_declined',
              refund: { amount_cents: 45_000, currency: 'eur', psp_reference: 're_3Q8x2L', reverses: 'pi_3Q8x2K' }
      subject_reachable ->(booking_id, identity) { Booking.readable_by?(booking_id, identity.user_id) }
    end

    kind :action
    description "Collect the hotel's answer to a paid booking: the confirmation code, or a refusal naming the " \
                'refund. Refused until the hotel answers, within minutes; wait on `booking_confirmation`.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   booking_id: { type: 'string', format: 'uuid', description: 'From reserve_room or my_bookings.' }
                 },
                 required: ['booking_id']
    output_schema type: 'object',
                  additionalProperties: false,
                  properties: {
                    booking_id: { type: 'string' },
                    status: { const: 'confirmed' },
                    confirmation_code: { type: 'string', description: 'The reference the guest gives at the desk.' }
                  },
                  required: %w[booking_id status confirmation_code]
    def confirm_booking
      @booking = ConfirmBookingOperation.call(booking_id: params[:booking_id])
    end
  end
end
