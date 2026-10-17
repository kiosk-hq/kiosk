# frozen_string_literal: true

# Appointments at the salon.
module Kiosk
  class AppointmentsController < ApplicationController
    include Kiosk::Handler

    SLOT     = { type: 'string', description: "Appointment time, on the salon's clock." }.freeze
    TIMEZONE = { type: 'string', description: "The salon's IANA zone." }.freeze

    kind :action
    description 'Book the signed-in customer into a salon at a future time, optionally for one service from ' \
                "the menu. A service's price is captured on the appointment; a booking without one carries no price."
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   salon_id: { type: 'integer', description: 'A salon from `salons`.' },
                   slot: { type: 'string', format: 'date-time',
                           description: 'Appointment time; must be in the future.' },
                   service_id: { type: 'integer', description: 'A service from `service_menu`.' }
                 },
                 required: %w[salon_id slot]
    output_schema oneOf: [
      { type: 'object', additionalProperties: false,
        description: 'A booking with a service.',
        properties: {
          appointment_id: { type: 'string', description: 'The appointment; `my_appointments` calls it `id`.' },
          salon_id: { type: 'integer', description: 'The salon.' },
          slot: SLOT,
          timezone: TIMEZONE,
          service: { type: 'string', description: 'The service booked.' },
          currency: { type: 'string', description: 'EUR.' },
          price_cents: { type: 'integer', description: 'EUR cents captured at booking.' },
          price_eur: { type: 'string', description: 'The price for a human, e.g. "€90".' }
        },
        required: %w[appointment_id salon_id slot timezone service currency price_cents price_eur] },
      { type: 'object', additionalProperties: false,
        description: 'A booking without a service.',
        properties: {
          appointment_id: { type: 'string', description: 'The appointment; `my_appointments` calls it `id`.' },
          salon_id: { type: 'integer', description: 'The salon.' },
          slot: SLOT,
          timezone: TIMEZONE
        },
        required: %w[appointment_id salon_id slot timezone] }
    ]
    example_params({ salon_id: 1, service_id: 3, slot: -> { BookAppointmentOperation.example_slot } })
    example_row({
                  appointment_id: '6b1f0c5a-9d3e-4f27-8a10-2c7e4b9d5f83', salon_id: 1,
                  slot: -> { BookAppointmentOperation.example_slot },
                  timezone: SalonClock::DEFAULT_ZONE_NAME, service: 'Colour',
                  currency: 'EUR', price_cents: 9000, price_eur: '€90'
                })
    def book_appointment
      @appointment = BookAppointmentOperation.call(
        customer_id: kiosk_identity.user_id,
        salon_id: params[:salon_id].to_i,
        slot: params[:slot],
        service_id: params[:service_id]&.to_i
      )
    end

    kind :query
    description "The signed-in customer's appointments."
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  description: 'Oldest first.',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      id: { type: 'string', description: 'The appointment; `book_appointment` calls it `appointment_id`.' },
                      salon_id: { type: 'integer', description: 'The salon.' },
                      slot: SLOT,
                      timezone: TIMEZONE
                    },
                    required: %w[id salon_id slot timezone]
                  }
    def my_appointments
      @appointments = Appointment.own.includes(:salon).order(:id)
    end

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
                          slot: SLOT,
                          timezone: TIMEZONE,
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
