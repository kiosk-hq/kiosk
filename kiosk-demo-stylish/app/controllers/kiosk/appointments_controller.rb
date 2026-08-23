# frozen_string_literal: true

# stylish's WRITE surface: the one verb an assistant reaches with
# `POST /kiosk/book_appointment` — arguments in the JSON body, and `kind :action`
# above the declaration is what puts it on `POST`. The action is six lines:
# arguments off the request, into an Operation, render what it answers (T-083).
#
# A refusal is an ordinary `render json:, status:` naming a code from the wire's
# closed error-code table — no Kiosk error classes appear below. The wire
# re-renders it as the RFC 9457 problem document whose TOP-LEVEL `code` an
# assistant branches on; {KioskRefusals#render_operation} is the one place an
# {OperationResult} becomes a status.
#
# NOT ROUTABLE — see Kiosk::FrontDeskController.
class Kiosk::AppointmentsController < ApplicationController
  include Kiosk::Handler
  include KioskRefusals

  # ADR-0023: no argument names and no "pass its `x`" clause — `input_schema`
  # declares those. This says what booking MEANS and where the refusals are.
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
                               description: "Appointment time, ISO 8601 timestamp. Must be LATER THAN NOW — " \
                                            "an instant that has passed is refused 400. Carry an offset " \
                                            "(\"…Z\", \"…+02:00\"); without one it is read in the salon's own clock." },
                 service_id: { type: "integer",
                               description: "Optional service id from availability/service_menu; its EUR price is captured." },
               },
               required: ["salon_id", "slot"]
  # The four price fields travel together or not at all: a bare salon booking
  # captures no price, and publishing `null`s for it would invent one.
  output_schema oneOf: [
    { type: "object", additionalProperties: false,
      description: "A booking WITH a service — its name and EUR price were captured.",
      properties: {
        appointment_id: { type: "string", description: "uuid — the booking. my_appointments calls the same value `id`." },
        salon_id:       { type: "integer", description: "The salon booked." },
        slot:           { type: "string", description: "Appointment time, ISO 8601." },
        service:        { type: "string", description: "The booked service's name, captured at booking time." },
        currency:       { type: "string", description: "EUR." },
        price_cents:    { type: "integer", description: "EUR cents captured on the booking." },
        price_eur:      { type: "string", description: "The same price rendered for a human, e.g. \"€90\"." },
      },
      required: %w[appointment_id salon_id slot service currency price_cents price_eur] },
    { type: "object", additionalProperties: false,
      description: "A bare salon booking — no service_id was passed, so nothing was priced.",
      properties: {
        appointment_id: { type: "string", description: "uuid — the booking." },
        salon_id:       { type: "integer", description: "The salon booked." },
        slot:           { type: "string", description: "Appointment time, ISO 8601." },
      },
      required: %w[appointment_id salon_id slot] },
  ]
  # THE SLOT IS RESOLVED, NOT WRITTEN DOWN (K-969): a past slot is refused, so a
  # literal would age into "copy this and get a 400". `example_params` takes a
  # resolvable slot ({Kiosk::Server::SchemaSlots}); the instant itself lives in
  # the Operation, quoted back by the two `slot` refusals as the shape to retry.
  example_params({ salon_id: 1, service_id: 3, slot: -> { BookAppointmentOperation.example_slot } })
  example_row({
    appointment_id: 1, salon_id: 1,
    slot: -> { BookAppointmentOperation.example_slot }, service: "Colour",
    currency: "EUR", price_cents: 9000, price_eur: "€90",
  })
  def book_appointment
    render_operation BookAppointmentOperation.call(
      principal_id: kiosk_identity.user_id, # forged params[:user_id] never consulted
      salon_id:     params[:salon_id],
      slot:         params[:slot],
      service_id:   params[:service_id],
    )
  end
end
