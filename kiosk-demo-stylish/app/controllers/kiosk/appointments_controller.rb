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

  description "Book a service for the authenticated visitor. Pick a service from the `availability`/`service_menu` query and pass its `service_id` — its name + EUR price are captured on the booking. Every service is always bookable (overbooking allowed; the salon never fills up), so a well-formed booking never fails for lack of capacity. (A bare `salon_id` booking without a service is also accepted — OMIT service_id for that; an unknown service_id is a 400, never a silently service-less booking.) A missing/unknown salon_id, an unparseable slot, or an unknown service_id each return 400 naming what was wrong."
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
