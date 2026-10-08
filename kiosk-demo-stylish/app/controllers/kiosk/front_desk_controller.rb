# frozen_string_literal: true

# The read verbs.
class Kiosk::FrontDeskController < ApplicationController
  include Kiosk::Handler

  kind :query
  description "Browse the public salon catalogue — every salon this front desk books for, each with " \
              "the IANA zone its chairs keep. Once the human picks one, `book_appointment` takes it " \
              "from there, on that salon's own clock."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The whole salon catalogue.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    salon_id: { type: "integer", description: "Pass to book_appointment as `salon_id`." },
                    name:     { type: "string", description: "Salon name." },
                    timezone: { type: "string",
                                description: "IANA zone this salon's chairs keep, e.g. Europe/Paris. " \
                                             "An appointment happens here, so an hour a human names is " \
                                             "an hour on this clock: build the offset `slot` carries " \
                                             "against it." },
                  },
                  required: %w[salon_id name timezone],
                }
  def salons
    render json: Salon.order(:id).pluck(:id, :name, :timezone).map { |id, name, zone|
      { salon_id: id, name: name, timezone: zone }
    }
  end

  kind :query
  description "Browse the salon's service menu, priced. Takes no arguments and returns the WHOLE " \
              "menu, so an empty answer would mean the " \
              "salon offers nothing at all. Once the human picks a service, `book_appointment` books " \
              "it and CAPTURES its price on the appointment, so a later price change never re-prices a " \
              "booking already made."
  input_schema type: "object",
               additionalProperties: false,
               properties: {},
               required: []
  output_schema type: "array",
                description: "The whole service menu, cheapest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    service_id:  { type: "integer", description: "Pass to book_appointment as `service_id`; its EUR price is captured on the booking." },
                    name:        { type: "string", description: "Service name." },
                    price_cents: { type: "integer", description: "EUR cents." },
                    currency:    { type: "string", description: "EUR." },
                    price_eur:   { type: "string", description: "The same price rendered for a human, e.g. \"€35\"." },
                  },
                  required: %w[service_id name price_cents currency price_eur],
                }
  example_params({})
  example_row({
    service_id: 1, name: "Cut", price_cents: 3500,
    currency: "EUR", price_eur: "€35",
  })
  def service_menu
    render json: Service.order(:price_cents).pluck(:id, :name, :price_cents)
                        .map { |id, name, price_cents|
                          { service_id: id, name: name, price_cents: price_cents,
                            currency: "EUR", price_eur: Service.format_eur(price_cents) }
                        }
  end

  kind :query
  description "Browse the salon's OPEN services. Every service on the menu is always bookable — this " \
              "salon is evergreen and has no finite capacity, so it never fills up and a booking never " \
              "fails for want of room. Takes no arguments. Once the human picks a row, " \
              "`book_appointment` books it and captures its price on the appointment."
  input_schema type: "object",
               additionalProperties: false,
               properties: {},
               required: []
  output_schema type: "array",
                description: "Every menu service, always bookable, cheapest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    service_id:  { type: "integer", description: "Pass to book_appointment as `service_id`; its EUR price is captured on the booking." },
                    service:     { type: "string", description: "Service name." },
                    price_cents: { type: "integer", description: "EUR cents." },
                    open:        { const: true, description: "Always true — capacity is infinite, so the salon never fills up." },
                    currency:    { type: "string", description: "EUR." },
                    price_eur:   { type: "string", description: "The same price rendered for a human, e.g. \"€90\"." },
                  },
                  required: %w[service_id service price_cents open currency price_eur],
                }
  example_params({})
  example_row({
    service_id: 3, service: "Colour", open: true,
    currency: "EUR", price_cents: 9000, price_eur: "€90",
  })
  def availability
    render json: Service.order(:price_cents).pluck(:id, :name, :price_cents)
                        .map { |id, name, price_cents|
                          { service_id: id, service: name, price_cents: price_cents,
                            open: true, currency: "EUR",
                            price_eur: Service.format_eur(price_cents) }
                        }
  end

  kind :query
  description "List this principal's appointments."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The principal's appointments, oldest id first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    id:       { type: "string", description: "uuid — the appointment. book_appointment calls the same value `appointment_id`." },
                    salon_id: { type: "integer", description: "The salon booked." },
                    slot:     { type: "string", description: "Appointment time, ISO 8601 carrying THIS SALON's offset — every verb of this demo publishes this field on the clock of the salon the row is about." },
                    timezone: { type: "string", description: "The IANA zone this row is rendered in — a property of the SALON, not of this operator: another salon in the same answer may be on a different one." },
                  },
                  required: %w[id salon_id slot timezone],
                }
  def my_appointments
    render json: Appointment.own.joins(:salon).order(:id)
                            .pluck("appointments.id", "appointments.salon_id",
                                   "appointments.slot", "salons.timezone")
                            .map { |id, salon_id, slot, timezone|
                              { id: id, salon_id: salon_id,
                                slot: SalonClock.publish(slot, Time.find_zone!(timezone)),
                                timezone: timezone }
                            }
  end

  kind :query
  reach :role
  description "Staff forecast — role-gated: owner sees ALL bookings + a FORECASTED € revenue total (summed from the actual bookings' prices, growing from €0 as visitors book); any other role sees only their own bookings and no forecast (role from the bound human's IdP)"
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The bookings this caller may see, slot-ordered; for an owner, a forecast row after them.",
                items: {
                  oneOf: [
                    { type: "object", additionalProperties: false,
                      description: "One booking.",
                      properties: {
                        id:          { type: "string", description: "uuid — the appointment." },
                        salon_id:    { type: "integer", description: "The salon booked." },
                        slot:        { type: "string", description: "Appointment time, ISO 8601 carrying THIS SALON's offset — every verb of this demo publishes this field on the clock of the salon the row is about." },
                        timezone:    { type: "string", description: "The IANA zone this row is rendered in — a property of the SALON, not of this operator." },
                        service_id:  { type: %w[integer null], description: "The booked service, or null for a bare salon booking." },
                        service:     { type: %w[string null], description: "The booked service's name, or null." },
                        price_cents: { type: %w[integer null], description: "EUR cents CAPTURED on the booking, or null when no service was booked." },
                        kind:        { const: "booking", description: "booking — this row is an appointment." },
                        currency:    { type: "string", description: "EUR." },
                        price_eur:   { type: "string", description: "The captured price rendered for a human; \"€0\" when none was captured." },
                      },
                      required: %w[id salon_id slot timezone service_id service price_cents kind currency price_eur] },
                    { type: "object", additionalProperties: false,
                      description: "The owner-only forecast trailer, appended after the bookings.",
                      properties: {
                        summary:        { const: "forecast", description: "forecast — this row is the summary, not an appointment." },
                        bookings:       { type: "integer", description: "How many booking rows this forecast sums." },
                        currency:       { type: "string", description: "EUR." },
                        forecast_cents: { type: "integer", description: "EUR cents summed from the real captured per-booking prices — €0 before any booking, growing with each one." },
                        forecast_eur:   { type: "string", description: "The same total rendered for a human." },
                      },
                      required: %w[summary bookings currency forecast_cents forecast_eur] },
                  ],
                }
  # An owner sees the whole book and a forecast summed from its captured
  # prices; anyone else sees their own bookings.
  def salon_calendar
    owner = Kiosk.current_role == "owner"
    bookings = (owner ? Appointment.all : Appointment.own)
               .left_joins(:service).joins(:salon).order(:slot)
               .pluck("appointments.id", "appointments.salon_id", "appointments.slot", "salons.timezone",
                      "appointments.service_id", "services.name", "appointments.price_cents")
               .map { |id, salon_id, slot, timezone, service_id, service, price_cents|
                 { id: id, salon_id: salon_id,
                   slot: SalonClock.publish(slot, Time.find_zone!(timezone)),
                   timezone: timezone, service_id: service_id,
                   service: service, price_cents: price_cents,
                   kind: "booking", currency: "EUR",
                   price_eur: Service.format_eur(price_cents) }
               }
    return render json: bookings unless owner

    forecast_cents = bookings.sum { _1[:price_cents].to_i }
    render json: bookings + [{ summary: "forecast", bookings: bookings.size, currency: "EUR",
                               forecast_cents: forecast_cents,
                               forecast_eur: Service.format_eur(forecast_cents) }]
  end
end
