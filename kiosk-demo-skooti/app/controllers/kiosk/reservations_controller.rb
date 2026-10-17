# frozen_string_literal: true

# Reservations: a held vehicle and the money paid for it.
class Kiosk::ReservationsController < ActionController::API
  include Kiosk::Handler

  topic :booking_payment do
    description 'A reservation of yours is paid; start its rental.'
    payload_schema type: 'object', additionalProperties: false,
                   properties: { reservation_id: { type: 'string', format: 'uuid' },
                                 payment_state: { enum: %w[paid] } },
                   required: %w[reservation_id payment_state]
    example reservation_id: 'a3f9c1e2-7b4d-4e8a-9c1f-2d6e5b0a3c7f', payment_state: 'paid'
    subject_reachable ->(reservation_id, identity) { Reservation.readable_by?(reservation_id, identity.user_id) }
  end

  kind :query
  description "Your reservations, newest first. Re-read it when a payment's answer never arrived: " \
              '`payment_state` says where the money stands.'
  input_schema type: 'object', additionalProperties: false, properties: {}, required: []
  output_schema type: 'array',
                items: {
                  type: 'object', additionalProperties: false,
                  properties: {
                    reservation_id: { type: 'string', description: 'Pass it to `start_rental` or `rent_motorcycle`.' },
                    scooter_code: { type: 'string', description: 'The vehicle reserved.' },
                    status: { type: 'string', description: '`reserved` until the rental starts, then `active`.' },
                    payment_state: { type: 'string', enum: %w[unpaid pending paid],
                                     description: '`paid`: nothing left to pay. `pending`: a charge is under way and ' \
                                                  'may already have taken the money; re-read, do not pay again. ' \
                                                  '`unpaid`: pay for it.' }
                  },
                  required: %w[reservation_id scooter_code status payment_state]
                }
  def my_reservations
    @reservations = Reservation.own.with_settlement(Kiosk::Settlement.own).includes(:scooter).order(created_at: :desc)
  end

  kind :action
  description 'Hold one vehicle and get the price of its first minute, which is what you pay now. ' \
              'Pay as `pay_hint` says, then start the rental.'
  input_schema type: 'object',
               additionalProperties: false,
               properties: {
                 scooter_code: { type: 'string', description: 'A `code` from `scooters_available`.' }
               },
               required: ['scooter_code']
  output_schema type: 'object',
                additionalProperties: false,
                properties: {
                  reservation_id: { type: 'string', description: "Name it in the cart's line item, then pass it to `start_rental` or `rent_motorcycle`." },
                  price_per_min_cents: { type: 'integer', description: "The amount to pay now, in cents: one minute at this vehicle's rate." },
                  currency: { type: 'string', description: 'The currency to pay in.' },
                  pay_hint: { type: 'string', description: 'The cart this hold expects, in words.' }
                },
                required: %w[reservation_id price_per_min_cents currency pay_hint]
  example_params({ scooter_code: 'SK-001' })
  example_row({
                reservation_id: 'a3f9c1e2-7b4d-4e8a-9c1f-2d6e5b0a3c7f', price_per_min_cents: 15, currency: 'eur',
                pay_hint: 'sign a cart in eur with total_amount_cents 15 and one line item …'
              })
  def reserve
    @reservation = Reservation.create!(user_id: kiosk_identity.user_id, scooter_code: params[:scooter_code])
  end
end
