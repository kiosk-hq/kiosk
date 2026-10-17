# frozen_string_literal: true

# The salon's book: every booking for the owner, a customer's own for anyone else.
module Kiosk
  class CalendarController < ApplicationController
    include Kiosk::Handler

    kind :query
    reach :role
    description "The salon's book in time order. The owner sees every booking and a revenue forecast summed from " \
                'their prices; a customer sees only their own bookings.'
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  description: 'Bookings in time order; for the owner, a forecast row after them.',
                  items: {
                    oneOf: [
                      { type: 'object', additionalProperties: false,
                        description: 'One booking.',
                        properties: {
                          id: { type: 'string', description: 'The appointment.' },
                          salon_id: { type: 'integer', description: 'The salon.' },
                          slot: AppointmentsController::SLOT,
                          timezone: AppointmentsController::TIMEZONE,
                          service_id: { type: %w[integer null], description: 'The service booked, if any.' },
                          service: { type: %w[string null], description: 'Its name.' },
                          price_cents: { type: %w[integer null], description: 'EUR cents captured at booking.' },
                          kind: { const: 'booking', description: 'Marks a booking row.' },
                          currency: { type: 'string', description: 'EUR.' },
                          price_eur: { type: 'string', description: 'The price for a human; "€0" without a service.' }
                        },
                        required: %w[id salon_id slot timezone service_id service price_cents kind currency price_eur] },
                      { type: 'object', additionalProperties: false,
                        description: "The owner's forecast, after the bookings.",
                        properties: {
                          summary: { const: 'forecast', description: 'Marks the forecast row.' },
                          bookings: { type: 'integer', description: 'How many bookings it sums.' },
                          currency: { type: 'string', description: 'EUR.' },
                          forecast_cents: { type: 'integer', description: "EUR cents, the sum of the bookings' prices." },
                          forecast_eur: { type: 'string', description: 'The total for a human.' }
                        },
                        required: %w[summary bookings currency forecast_cents forecast_eur] }
                    ]
                  }
    def salon_calendar
      @owner = Kiosk.current_role == 'owner'
      @appointments = (@owner ? Appointment.all : Appointment.own).includes(:salon, :service).order(:slot)
    end
  end
end
