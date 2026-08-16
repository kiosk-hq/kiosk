# frozen_string_literal: true

# stylish's WRITE surface: the one verb an assistant reaches with
# `POST /kiosk/run`. Same shape as Kiosk::FrontDeskController — this app's own
# ApplicationController plus `include Kiosk::Action` — because a controller
# declares queries OR actions, never both.
#
# Errors are Rails' idiom end to end: the wire's `error.code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code, and the wire carries it verbatim. No
# Kiosk error classes appear below.
#
# NOT ROUTABLE — see Kiosk::FrontDeskController.
class Kiosk::AppointmentsController < ApplicationController
  include Kiosk::Action

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
  example_params({ salon_id: 1, service_id: 3, slot: "2026-08-05T14:00:00Z" })
  example_row({
    appointment_id: 1, salon_id: 1,
    slot: "2026-08-05T14:00:00Z", service: "Colour",
    currency: "EUR", price_cents: 9000, price_eur: "€90",
  })
  def book_appointment
    # Identity is set via Kiosk::Server::SessionContext SET LOCAL —
    # current_user_id() helper returns the principal. ActiveRecord doesn't
    # have direct access; pull from PG. (The mixin's `kiosk_identity` carries the
    # same principal, but the GUC is what the queries next door scope on, so the
    # write side reads the same source rather than a second one that could drift.)
    user_id = ActiveRecord::Base.connection.execute(
      "SELECT kiosk.current_user_id() AS uid",
    ).first["uid"]

    # ── Input guards (K-692) ─────────────────────────────────────────────────
    # Validate the inputs with clean 400s instead of letting create! (or the
    # column's NOT NULL) raise a RecordInvalid/NotNullViolation that surfaces as
    # an opaque 500. philslist's `post_listing` is the in-repo model and its
    # reason applies verbatim: the error must name what was wrong, and what the
    # valid values are, so an assistant that guessed can recover without fetching
    # the schema first.
    salon_id = params[:salon_id]
    return render_bad_request(
      "missing field: salon_id — pass the `salon_id` from the `salons` query",
    ) if salon_id.blank?
    return render_bad_request(
      "unknown salon_id #{salon_id.inspect} — call the `salons` query for the bookable salons",
    ) unless Salon.exists?(id: salon_id)

    # `slot` needs a guard philslist has no equivalent for, because ActiveRecord's
    # timestamp cast does not fail loudly and fails in TWO different directions:
    # "banana" casts to nil and detonates the column's NOT NULL as a 500, while
    # "next tuesday" casts to TODAY AT MIDNIGHT and was booked silently — a real
    # appointment, in the past, that the agent never asked for. Parse it here,
    # strictly, and say what shape was wanted.
    raw_slot = params[:slot]
    return render_bad_request(
      "missing field: slot — an ISO 8601 timestamp, e.g. \"2026-10-01T14:00:00Z\"",
    ) if raw_slot.blank?
    slot = begin
      Time.iso8601(raw_slot.to_s)
    rescue ArgumentError, TypeError
      return render_bad_request(
        "invalid slot #{raw_slot.inspect} — pass an ISO 8601 timestamp, e.g. \"2026-10-01T14:00:00Z\"",
      )
    end

    # The chosen service (its price is captured at book time — the menu can change
    # later; the booked price is what the calendar and forecast report).
    # service_id is OPTIONAL — a bare salon_id booking is legitimate and the
    # descriptor says so — but a service_id that names NOTHING must not be
    # silently dropped: that booked an appointment with no service and
    # price_cents NULL, which the owner's revenue forecast then summed as €0
    # while the calendar rendered it as an ordinary row. Nothing surfaced it.
    service = nil
    unless params[:service_id].nil? || params[:service_id].to_s.strip.empty?
      service = Service.find_by(id: params[:service_id])
      return render_bad_request(
        "unknown service_id #{params[:service_id].inspect} — bookable services: " \
        "#{Service.order(:id).pluck(:id, :name).map { |id, n| "#{id} (#{n})" }.join(', ')}; " \
        "or omit service_id for a bare salon booking",
      ) unless service
    end

    appointment = Appointment.create!(
      user_id:     user_id, # forged params[:user_id] never consulted
      salon_id:    salon_id,
      slot:        slot,
      service_id:  service&.id,
      price_cents: service&.price_cents,
    )

    result = {
      appointment_id: appointment.id,
      salon_id:       appointment.salon_id,
      slot:           appointment.slot.iso8601,
    }
    if service
      result.merge!(
        service:     service.name,
        currency:    "EUR",
        price_cents: service.price_cents,
        price_eur:   service.price_eur,
      )
    end

    render json: result
  end

  private

  # The whole error surface of this controller is one refusal, and it is a plain
  # `render json:, status:` naming a code from the wire's closed vocabulary.
  # Naming it is what lets an assistant branch; the status alone would already
  # imply this one, but writing it keeps the answer explicit.
  def render_bad_request(message)
    render json: { error: { code: "bad_request", message: message } },
           status: :bad_request
  end
end
