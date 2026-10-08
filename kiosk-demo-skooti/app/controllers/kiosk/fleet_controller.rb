# frozen_string_literal: true

# The read verbs.
class Kiosk::FleetController < ActionController::API
  include Kiosk::Handler

  kind :query
  description "Browse the available fleet — each row carries the vehicle's name and pickup dock/location " \
              "so you can pick one by name or nearest dock. needs_licence flags the KYC-gated combustion " \
              "motorcycle (rent it via rent_motorcycle); licence-free scooters use start_rental. " \
              "A cart is signed at the total the operator quotes, never at a per-minute rate " \
              "multiplied out by the caller. Reference a " \
              "vehicle by its `code` (e.g. \"SK-001\") when reserving."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The whole available fleet.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    code:                { type: "string", description: "The ONLY vehicle handle on the wire — pass it to reserve as `scooter_code`." },
                    name:                { type: "string", description: "The vehicle's given name." },
                    dock:                { type: "string", description: "Pickup dock/location." },
                    status:              { type: "string", description: "available — this verb lists only what is." },
                    kind:                { type: "string", description: "scooter | motorcycle." },
                    needs_licence:       { type: "boolean", description: "True for the KYC-gated combustion motorcycle: rent it with rent_motorcycle, not start_rental." },
                    lat:                 { type: "string", description: "Latitude as a decimal STRING (e.g. \"52.3739\")." },
                    lng:                 { type: "string", description: "Longitude as a decimal STRING (e.g. \"4.8809\")." },
                    price_per_min_cents: { type: "integer", description: "EUR cents PER MINUTE." },
                    currency:            { type: "string", description: "eur — the currency the cart must be signed in." },
                  },
                  required: %w[code name dock status kind needs_licence lat lng
                               price_per_min_cents currency],
                }
  example_params({})
  example_row({
    code: "SK-001", name: "Jordaan Jet", dock: "Jordaan Dock",
    status: "available", kind: "scooter", needs_licence: false,
    lat: "52.3739", lng: "4.8809", price_per_min_cents: 15, currency: "eur",
  })
  def scooters_available
    render json: Scooter.available.order(:id).map { |scooter|
      { code:                scooter.code,
        name:                scooter.name,
        dock:                scooter.dock,
        status:              scooter.status,
        kind:                scooter.kind,
        needs_licence:       scooter.needs_licence,
        lat:                 scooter.lat,
        lng:                 scooter.lng,
        price_per_min_cents: scooter.price_per_min_cents,
        currency:            "eur" }
    }
  end

  kind :query
  description "List this principal's fleet reservations (scoped to the authenticated account). " \
              "This is the query to re-read after a payment whose response never arrived: each row " \
              "says where that reservation stands with the fleet and where its money stands, and a " \
              "reservation whose charge is still outstanding says so rather than reporting itself " \
              "unpaid. Each row also names the vehicle by the same handle the fleet catalog shows, " \
              "so a rental can be started straight from this answer."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The principal's reservations, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    reservation_id: { type: "string", description: "uuid. Pass to start_rental / rent_motorcycle as `reservation_id`." },
                    scooter_code:   { type: "string", description: "The vehicle's `code` — the same handle scooters_available shows and reserve takes." },
                    status:         { type: "string", description: "The ride's own state: reserved | active. It says nothing about money — payment_state does." },
                    payment_state:  { type: "string", enum: %w[unpaid pending paid],
                                      description: "Where this reservation's money stands, anchored to the CAPTURE and not to the operator's settlement record. `paid` = the charge went through; there is nothing to retry. `pending` = a capture for this reservation has been started and its outcome is not known yet — it may already have taken the money, so do NOT sign a fresh mandate chain: wait and re-read. `unpaid` = no capture has ever been started, and this is the only answer that makes a fresh chain correct." },
                  },
                  required: %w[reservation_id scooter_code status payment_state],
                }
  def my_reservations
    reservations = Reservation.own.with_settlement(Kiosk::Settlement.own).includes(:scooter).order(created_at: :desc)
    render json: reservations.map { |reservation|
      { reservation_id: reservation.id,
        scooter_code:   reservation.scooter.code,
        status:         reservation.status,
        payment_state:  reservation.payment_state }
    }
  end
end
