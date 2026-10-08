# frozen_string_literal: true

# The write verb. The work is in app/operations.
class Kiosk::AppointmentsController < ApplicationController
  include Kiosk::Handler

  kind :action
  description "Book an appointment for the authenticated visitor. Naming a service is OPTIONAL and " \
              "the two forms differ in what the appointment records: pick one from the menu and its " \
              "name and price are CAPTURED on the appointment, or book the salon alone and the " \
              "appointment carries no price at all. What never happens is the middle — asking for a " \
              "service this salon does not offer is never quietly turned into a service-less " \
              "booking. Every service is always bookable (this salon overbooks by design " \
              "and never fills up), so a well-formed booking never fails for want of room. This " \
              "salon records no booking in the past either, so the instant asked for must still be " \
              "ahead of now."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 salon_id:   { type: "integer",
                               description: "Salon id from the salons query." },
                 slot:       { type: "string", format: "date-time",
                               description: "Appointment time, RFC 3339 timestamp, and the OFFSET IS REQUIRED " \
                                            "(\"…Z\", \"…+02:00\"): an appointment is an instant, so a value " \
                                            "without one is refused 400 rather than completed on anybody's " \
                                            "clock. Must also be LATER THAN NOW — an instant that has passed " \
                                            "is refused 400. The answer names the salon's own zone as " \
                                            "`timezone`, which is where the chair is." },
                 service_id: { type: "integer",
                               description: "Service id from availability/service_menu; its EUR price is captured." },
               },
               required: ["salon_id", "slot"]
  output_schema oneOf: [
    { type: "object", additionalProperties: false,
      description: "A booking WITH a service — its name and EUR price were captured.",
      properties: {
        appointment_id: { type: "string", description: "uuid — the booking. my_appointments calls the same value `id`." },
        salon_id:       { type: "integer", description: "The salon booked." },
        slot:           { type: "string", description: "Appointment time, ISO 8601 carrying THIS SALON's offset — every verb of this demo publishes this field on the clock of the salon the row is about." },
        timezone:       { type: "string", description: "The IANA zone this row is rendered in — a property of the SALON, not of this operator." },
        service:        { type: "string", description: "The booked service's name, captured at booking time." },
        currency:       { type: "string", description: "EUR." },
        price_cents:    { type: "integer", description: "EUR cents captured on the booking." },
        price_eur:      { type: "string", description: "The same price rendered for a human, e.g. \"€90\"." },
      },
      required: %w[appointment_id salon_id slot timezone service currency price_cents price_eur] },
    { type: "object", additionalProperties: false,
      description: "A bare salon booking — no service_id was passed, so nothing was priced.",
      properties: {
        appointment_id: { type: "string", description: "uuid — the booking." },
        salon_id:       { type: "integer", description: "The salon booked." },
        slot:           { type: "string", description: "Appointment time, ISO 8601 carrying THIS SALON's offset — every verb of this demo publishes this field on the clock of the salon the row is about." },
        timezone:       { type: "string", description: "The IANA zone this row is rendered in — a property of the SALON, not of this operator." },
      },
      required: %w[appointment_id salon_id slot timezone] },
  ]
  example_params({ salon_id: 1, service_id: 3, slot: -> { BookAppointmentOperation.example_slot } })
  example_row({
    appointment_id: "6b1f0c5a-9d3e-4f27-8a10-2c7e4b9d5f83", salon_id: 1,
    slot: -> { BookAppointmentOperation.example_slot },
    timezone: SalonClock::DEFAULT_ZONE_NAME, service: "Colour",
    currency: "EUR", price_cents: 9000, price_eur: "€90",
  })
  def book_appointment
    render json: BookAppointmentOperation.call(
      principal_id: kiosk_identity.user_id,
      salon_id:     params[:salon_id].to_i,
      slot:         params[:slot],
      service_id:   params[:service_id]&.to_i,
    )
  end
end
