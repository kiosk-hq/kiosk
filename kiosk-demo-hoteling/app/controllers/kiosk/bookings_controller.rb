# frozen_string_literal: true

# The customer's room bookings.

module Kiosk
  class BookingsController < ActionController::API
    include Kiosk::Handler

    BOOKING_ID = '0b6f3a52-4c1e-4d7a-9a3e-6f2d8c1b5e70'

    topic :booking_payment do
      description "A booking was charged. The hotel's answer follows on `booking_confirmation`."
      payload_schema type: 'object', additionalProperties: false,
                     properties: { booking_id: { type: 'string', format: 'uuid' },
                                   payment_state: { enum: %w[paid] } },
                     required: %w[booking_id payment_state]
      example booking_id: BOOKING_ID, payment_state: 'paid'
      subject_reachable ->(booking_id, identity) { Booking.readable_by?(booking_id, identity.user_id) }
    end

    topic :booking_confirmation do
      description '`confirmed`, with the code the guest gives at the desk, or `cancelled` with its `reason`: ' \
                  '`property_declined` (the hotel declined a paid booking; `refund` goes to the card that paid) ' \
                  'or `hold_lapsed` (unpaid past its pay-by time; nothing was charged).'
      payload_schema type: 'object', additionalProperties: false,
                     properties: { booking_id: { type: 'string', format: 'uuid' },
                                   status: { enum: %w[confirmed cancelled] },
                                   confirmation_code: { type: 'string' },
                                   reason: { enum: %w[property_declined hold_lapsed] },
                                   refund: { type: 'object', additionalProperties: false,
                                             properties: {
                                               amount_cents: { type: 'integer' },
                                               currency: { type: 'string' },
                                               psp_reference: { type: 'string' },
                                               reverses: { type: 'string', description: 'The charge this refund reverses.' }
                                             } } },
                     required: %w[booking_id status]
      example booking_id: BOOKING_ID, status: 'confirmed', confirmation_code: '5d1c9e04-8f2b-4a6e-b3c7-2e9f0a4d6b18'
      example booking_id: BOOKING_ID, status: 'cancelled', reason: 'property_declined',
              refund: { amount_cents: 45_000, currency: 'eur', psp_reference: 're_3Q8x2L', reverses: 'pi_3Q8x2K' }
      example booking_id: BOOKING_ID, status: 'cancelled', reason: 'hold_lapsed'
      subject_reachable ->(booking_id, identity) { Booking.readable_by?(booking_id, identity.user_id) }
    end

    kind :query
    description "The signed-in customer's bookings, newest first. Re-read it after a payment whose answer " \
                'never arrived: each row says where the stay and its money stand.'
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      booking_id: { type: 'string', description: 'The booking reserve_room held.' },
                      property_id: { type: 'integer' },
                      room_type_id: { type: 'integer' },
                      check_in: { type: 'string', description: 'First night.' },
                      check_out: { type: 'string', description: 'Checkout day.' },
                      total_cents: { type: 'integer', description: 'Price of the whole stay, in cents.' },
                      status: { type: 'string', enum: %w[reserved confirmed cancelled],
                                description: 'The stay: held, confirmed by the hotel, or cancelled (declined by ' \
                                             'the hotel, or held unpaid past its pay-by time).' },
                      payment_state: { type: 'string', enum: %w[unpaid pending paid refunded],
                                       description: '`paid`: charged. `pending`: a charge is in progress; wait and ' \
                                                    're-read, do not pay again. `unpaid`: nothing charged. ' \
                                                    '`refunded`: the hotel declined and the charge was returned.' },
                      confirmation_code: { type: %w[string null],
                                           description: 'The reference the guest gives at the desk; null until confirmed.' }
                    },
                    required: %w[booking_id property_id room_type_id check_in check_out
                                 total_cents status payment_state confirmation_code]
                  }
    def my_bookings
      @bookings = Booking.own.with_settlement(Kiosk::Settlement.own).order(created_at: :desc)
    end

    kind :action
    description "Hold a room type for a stay for #{Booking::PAY_WINDOW.inspect}. Nothing is charged: pay the " \
                'quoted total with a cart naming the booking; the hotel answers on `booking_confirmation`, and ' \
                '`my_bookings` shows the answer and its confirmation code. A hold left unpaid ' \
                'past that time is cancelled, `booking_confirmation` says so, and its room is free for other guests.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   room_type_id: { type: 'integer', description: 'From an availability or hotel_detail row for these dates.' },
                   check_in: { type: 'string', format: 'date',
                               description: "First night, on the hotel's own clock. Tonight is bookable." },
                   check_out: { type: 'string', format: 'date',
                                description: "Checkout day; at most #{Booking::MAX_NIGHTS} nights after check_in." }
                 },
                 required: %w[room_type_id check_in check_out]
    output_schema type: 'object',
                  additionalProperties: false,
                  properties: {
                    booking_id: { type: 'string',
                                  description: "Name it in the cart's line item; my_bookings lists it." },
                    total_cents: { type: 'integer',
                                   description: 'Price of the whole stay, in cents; sign the cart at exactly this.' },
                    currency: { type: 'string', description: 'Sign the cart in this currency.' },
                    nights: { type: 'integer' },
                    nightly_price_cents: { type: 'integer', description: 'Price per night, in cents.' },
                    pay_hint: { type: 'string', description: 'The cart this hold expects, in words.' }
                  },
                  required: %w[booking_id total_cents currency nights nightly_price_cents pay_hint]
    def reserve_room
      @booking = ReserveRoomOperation.call(
        customer_id: kiosk_identity.user_id,
        room_type_id: params[:room_type_id].to_i,
        check_in: params[:check_in],
        check_out: params[:check_out]
      )
    end
  end
end
