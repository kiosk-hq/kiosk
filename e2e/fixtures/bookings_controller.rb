# frozen_string_literal: true

# The e2e origin's APPOINTMENTS resource, and the harness's proof that ONE
# controller may declare BOTH kinds (K-921): `my_appointments` is a query
# (`GET /kiosk/my_appointments`) and `book_appointment` is an action
# (`POST /kiosk/book_appointment`), and the two sit here together because they
# are the read and the write of the same thing. The kind is a property of each
# DECLARATION — the `kind` macro below — never of the class. See
# Kiosk::CatalogController for why neither is routed by hand.
#
# The SQL is deliberately RAW: `my_appointments` is the harness's headline
# security assertion — per-principal isolation with no RLS — and it is the
# SQL-side `kiosk.current_user_id()` predicate that proves it.
class Kiosk::BookingsController < ApplicationController
  include Kiosk::Handler

  # my_appointments — per-user appointment list scoped by the session GUC.
  # The WHERE is provider-controlled; the agent supplies no user filter.
  # App-layer per-user isolation without RLS: the principal sees only rows
  # where user_id matches kiosk.current_user_id(), enforced in the query.
  kind :query
  description "List the appointments belonging to the authenticated principal. " \
              "The caller cannot widen this: the scope is the provider's, taken " \
              "from the authenticated session, so another principal's bookings " \
              "are never returned. Returns the complete set (not paginated)."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The principal's own appointments, complete and not paginated.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    id:       { type: "string", description: "uuid — the appointment. book_appointment calls the same value `appointment_id`." },
                    salon_id: { type: "integer", description: "The salon booked." },
                    slot:     { type: "string", description: "Appointment time, ISO 8601." },
                  },
                  required: %w[id salon_id slot],
                }
  example_params({})
  # A UUID, because `appointments.id` IS a uuid (`create_table :appointments,
  # id: :uuid`) and the `output_schema` above says so. It published `1` until
  # 2026-08-20, when e2e/schema_conformance.rb — the first thing ever to check
  # a descriptor's examples against that descriptor's own schemas (§8.3,
  # matrix SPEC-084) — refused it on its first run. An assistant that copied
  # this row verbatim built an integer id for a value the wire never returns
  # as one. K-825.
  example_row({ id: "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f", salon_id: 1,
                slot: "2026-06-15T14:00:00Z" })
  def my_appointments
    render json: ActiveRecord::Base.connection.execute(
      "SELECT id, salon_id, slot FROM appointments " \
      "WHERE user_id = kiosk.current_user_id() " \
      "ORDER BY id",
    ).to_a
  end

  # book_appointment — reserves a slot for the CALLING principal. The owner is
  # never a parameter: it is read from the session GUC, so an agent cannot book
  # on someone else's behalf by supplying an id.
  kind :action
  description "Reserve a slot at one of this provider's salons for the " \
              "authenticated principal. This is a COMMITMENT, not a quote — it " \
              "creates the booking immediately. The booking is made for the " \
              "caller; there is no way to book on another principal's behalf. " \
              "Call `salons` first to choose where, and `my_appointments` " \
              "afterwards to see what is booked."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 salon_id: { type: "integer",
                             description: "The `id` of a row returned by the salons query." },
                 slot:     { type: "string", format: "date-time",
                             description: "Appointment time as an ISO 8601 timestamp, e.g. 2026-06-15T14:00:00Z." },
               },
               required: %w[salon_id slot]
  output_schema type: "object",
                description: "The booking that was just created.",
                additionalProperties: false,
                properties: {
                  appointment_id: { type: "string", description: "uuid — the booking. my_appointments calls the same value `id`." },
                  salon_id:       { type: "integer", description: "The salon booked, echoed." },
                  slot:           { type: "string", description: "Appointment time, ISO 8601." },
                },
                required: %w[appointment_id salon_id slot]
  example_params({ salon_id: 1, slot: "2026-06-15T14:00:00Z" })
  # A UUID for the same reason `my_appointments` publishes one: this IS the
  # same value under its other name, `appointments.id` is a uuid column, and
  # the declaration above says `type: "string"`. Caught by
  # e2e/schema_conformance.rb's §8.3 check on its first run — K-825.
  example_row({ appointment_id: "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f", salon_id: 1,
                slot: "2026-06-15T14:00:00Z" })
  def book_appointment
    # Identity is set via Kiosk::Server::SessionContext SET LOCAL —
    # current_user_id() helper returns the principal. ActiveRecord doesn't
    # have direct access; pull from PG.
    user_id = ActiveRecord::Base.connection.execute(
      "SELECT kiosk.current_user_id() AS uid",
    ).first["uid"]

    appointment = Appointment.create!(
      user_id:  user_id,
      salon_id: params[:salon_id],
      slot:     params[:slot],
    )

    render json: {
      appointment_id: appointment.id,
      salon_id:       appointment.salon_id,
      slot:           appointment.slot.iso8601,
    }
  end
end
