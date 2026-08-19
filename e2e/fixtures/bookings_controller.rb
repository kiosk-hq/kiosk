# frozen_string_literal: true

# The e2e origin's WRITE surface: the one verb an assistant reaches with
# `POST /kiosk/<action-name>`. See Kiosk::CatalogController for why the two
# halves are separate classes and why neither is routed by hand.
class Kiosk::BookingsController < ApplicationController
  include Kiosk::Action

  # book_appointment — reserves a slot for the CALLING principal. The owner is
  # never a parameter: it is read from the session GUC, so an agent cannot book
  # on someone else's behalf by supplying an id.
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
  example_params({ salon_id: 1, slot: "2026-06-15T14:00:00Z" })
  example_row({ appointment_id: 1, salon_id: 1, slot: "2026-06-15T14:00:00Z" })
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
