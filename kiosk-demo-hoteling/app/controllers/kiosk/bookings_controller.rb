# frozen_string_literal: true

# The customer's room bookings.

class Kiosk::BookingsController < ActionController::API
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
    example booking_id: BOOKING_ID, status: 'confirmed', confirmation_code: '5d1c9e04-8f2b-4a6e-b3c7-2e9f0a4d6b18'
    example booking_id: BOOKING_ID, status: 'cancelled', reason: 'property_declined',
            refund: { amount_cents: 45_000, currency: 'eur', psp_reference: 're_3Q8x2L', reverses: 'pi_3Q8x2K' }
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
                    booking_id: { type: 'string', description: 'Pass to confirm_booking.' },
                    property_id: { type: 'integer' },
                    room_type_id: { type: 'integer' },
                    check_in: { type: 'string', description: 'First night.' },
                    check_out: { type: 'string', description: 'Checkout day.' },
                    total_cents: { type: 'integer', description: 'Price of the whole stay, in cents.' },
                    status: { type: 'string', enum: %w[reserved confirmed cancelled],
                              description: 'The stay: held, confirmed by the hotel, or cancelled.' },
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
  description 'Hold a room type for a stay. Nothing is charged: pay the quoted total with a cart naming ' \
              'the booking, then call `confirm_booking`.'
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
                                description: "Name it in the cart's line item; pass it to confirm_booking." },
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
      agent_id: kiosk_identity.agent_id,
      room_type_id: params[:room_type_id].to_i,
      check_in: params[:check_in],
      check_out: params[:check_out]
    )
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
