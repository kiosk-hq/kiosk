# frozen_string_literal: true

# The salon's book: every booking for the owner, a customer's own for anyone else.
module Kiosk
  class CalendarController < ActionController::API
    include Kiosk::Handler

    kind :query
    reach :role
    description "The salon's book in time order. The owner sees every booking with its price; a customer sees " \
                'only their own bookings.'
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  description: 'Bookings in time order.',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      id: { type: 'string', description: 'The appointment.' },
                      salon_id: { type: 'integer', description: 'The salon.' },
                      slot: AppointmentsController::SLOT,
                      timezone: AppointmentsController::TIMEZONE,
                      service_id: { type: %w[integer null], description: 'The service booked, if any.' },
                      service: { type: %w[string null], description: 'Its name.' },
                      price_cents: { type: %w[integer null], description: 'In cents, captured at booking.' },
                      currency: { type: 'string', description: "The price's currency." },
                      price_eur: { type: 'string', description: 'The price for a human; "€0" without a service.' }
                    },
                    required: %w[id salon_id slot timezone service_id service price_cents currency price_eur]
                  }
    def salon_calendar
      @appointments = (Kiosk.current_role == 'owner' ? Appointment.all : Appointment.own).includes(:salon, :service).order(:slot)
    end
  end
end
