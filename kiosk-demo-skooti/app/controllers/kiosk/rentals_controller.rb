# frozen_string_literal: true

# Rentals: a paid reservation started, with the token that unlocks its vehicle.
class Kiosk::RentalsController < ActionController::API
  include Kiosk::Handler

  RESERVATION_ID = { type: 'string', format: 'uuid',
                     description: 'A `reservation_id` from `reserve` or `my_reservations`.' }.freeze

  RENTAL = {
    type: 'object',
    additionalProperties: false,
    properties: {
      scooter_code: { type: 'string', description: 'The vehicle this rental unlocks.' },
      rental_token: { type: 'string',
                      description: 'A signed, single-use unlock token for this vehicle; the lock checks it offline.' },
      unlock_url: { type: 'string', format: 'uri',
                    description: 'The page to give your human, verbatim and once: it carries the token and its QR, ' \
                                 'which opens the App Clip that writes the token to the lock.' },
      exp: { type: 'integer', description: 'When the token expires, in Unix seconds.' }
    },
    required: %w[scooter_code rental_token unlock_url exp]
  }.freeze

  kind :action
  description 'Start the rental of a paid, licence-free vehicle and get its unlock link.'
  input_schema type: 'object', additionalProperties: false,
               properties: { reservation_id: RESERVATION_ID }, required: ['reservation_id']
  output_schema(**RENTAL)
  def start_rental
    @rental = StartRentalOperation.call(reservation_id: params[:reservation_id])
    render :rental
  end

  kind :action
  description 'Start the rental of a paid motorcycle and get its unlock link. Needs your verified ' \
              '`age_over_18` and `licence_a`.'
  input_schema type: 'object', additionalProperties: false,
               properties: { reservation_id: RESERVATION_ID }, required: ['reservation_id']
  output_schema(**RENTAL)
  def rent_motorcycle
    @rental = RentMotorcycleOperation.call(reservation_id: params[:reservation_id])
    render :rental
  end
end
