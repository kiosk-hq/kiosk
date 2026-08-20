# frozen_string_literal: true

# stylish's WRITE surface: the one verb an assistant reaches with
# `POST /kiosk/book_appointment` — its own endpoint, arguments in the JSON body.
# Same shape as Kiosk::FrontDeskController — this app's own
# ApplicationController plus `include Kiosk::Action` — because a controller
# declares queries OR actions, never both.
#
# Errors are Rails' idiom end to end: the wire's error-code vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code, and the wire re-renders it as the
# RFC 9457 problem document whose TOP-LEVEL `code` an assistant branches on. No
# Kiosk error classes appear below — the Operation answers with an
# {OperationResult} and {KioskRefusals#render_operation} is the one place that
# becomes a status.
#
# THE WRITE IS SIX LINES: read the arguments off the request, hand them to an
# Operation, render what it answers (T-083, Phil's 2026-08-17
# WRITE-OPERATIONS-SEAM decision). That is the fleet's shape, not this demo's
# invention — `book_appointment`'s three input guards are the whole K-692
# argument, and a guard that `render`s cannot be exercised from a console or
# reused by a second door.
#
# NOT ROUTABLE — see Kiosk::FrontDeskController.
class Kiosk::AppointmentsController < ApplicationController
  include Kiosk::Action
  include KioskRefusals

  # ADR-0023: no argument names and no "pass its `x`" clause. `input_schema`
  # below declares all three arguments, which is optional, and what each one is
  # read from; this says what booking MEANS here and where the refusals are.
  description "Book an appointment for the authenticated visitor. Naming a service is OPTIONAL and " \
              "the two forms differ in what the appointment records: pick one from the menu and its " \
              "name and price are CAPTURED on the appointment, or book the salon alone and the " \
              "appointment carries no price at all. What never happens is the middle — asking for a " \
              "service this salon does not offer is refused 400, never quietly turned into a " \
              "service-less booking. Every service is always bookable (this salon overbooks by design " \
              "and never fills up), so a well-formed booking never fails for want of room; a salon " \
              "that does not exist, a time that cannot be parsed and a service that is unknown each " \
              "come back 400 naming what was wrong."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 salon_id:   { type: "integer",
                               description: "Salon id from the salons query." },
                 slot:       { type: "string", format: "date-time",
                               description: "Appointment time, ISO 8601 timestamp." },
                 service_id: { type: "integer",
                               description: "Optional service id from availability/service_menu; its EUR price is captured." },
               },
               required: ["salon_id", "slot"]
  # The four price fields are present ONLY when a service was booked — a bare
  # salon booking captures no price, so publishing `null`s for it would invent
  # a price of nothing. The `oneOf` is what says that, and it is why `service`
  # and `currency`/`price_cents`/`price_eur` travel together or not at all.
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
  example_params({ salon_id: 1, service_id: 3, slot: "2026-08-05T14:00:00Z" })
  example_row({
    appointment_id: 1, salon_id: 1,
    slot: "2026-08-05T14:00:00Z", service: "Colour",
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
