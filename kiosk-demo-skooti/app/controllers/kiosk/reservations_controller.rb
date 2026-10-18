# frozen_string_literal: true

# Reservations: a held vehicle and the money paid for it.
module Kiosk
  class ReservationsController < ActionController::API
    include Kiosk::Handler

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
                      payment_state: Kiosk::Payable::STATE_SCHEMA
                    },
                    required: %w[reservation_id scooter_code status payment_state]
                  }
    def my_reservations
      @reservations = Reservation.own.with_settlement(Kiosk::Settlement.own).includes(:scooter).order(created_at: :desc)
    end

    kind :action
    description "Hold one vehicle for #{Reservation::HOLD.inspect} and get the price of its first minute, which is " \
                'what you pay now. Pay with the `cart` it returns, then start the rental within the hold: a paid hold ' \
                'whose ride has not started by then is released and refunded. A vehicle another rider holds is refused ' \
                'as a conflict.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   scooter_code: { type: 'string', description: 'A `code` from `scooters_available`.' }
                 },
                 required: ['scooter_code']
    output_schema type: 'object',
                  additionalProperties: false,
                  properties: {
                    reservation_id: { type: 'string', description: 'Pass it to `start_rental` or `rent_motorcycle` once paid.' },
                    price_per_min_cents: { type: 'integer', description: "The amount to pay now, in cents: one minute at this vehicle's rate." },
                    currency: { type: 'string', description: 'The currency to pay in.' },
                    cart: Kiosk::Payable::CART_SCHEMA
                  },
                  required: %w[reservation_id price_per_min_cents currency cart]
    example_params({ scooter_code: 'SK-001' })
    example_row({
                  reservation_id: 'a3f9c1e2-7b4d-4e8a-9c1f-2d6e5b0a3c7f', price_per_min_cents: 15, currency: 'eur',
                  cart: { currency: 'eur', total_amount_cents: 15,
                          line_items: [{ reservation_id: 'a3f9c1e2-7b4d-4e8a-9c1f-2d6e5b0a3c7f' }, { qty: 1, price_cents: 15 }] }
                })
    def reserve
      @reservation = Reservation.create!(user_id: kiosk_identity.user_id, scooter_code: params[:scooter_code])
    rescue ActiveRecord::ExclusionViolation
      raise Kiosk::Server::Errors::Conflict,
            "#{params[:scooter_code]} is held by another rider — pick another vehicle from scooters_available"
    end
  end
end
