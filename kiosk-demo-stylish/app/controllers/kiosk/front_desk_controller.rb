# frozen_string_literal: true

# stylish's READ surface: the five verbs an assistant reaches with
# `GET /kiosk/<query-name>` — one endpoint each, arguments in the query string.
# Kiosk ships a MIXIN, not a base class: the superclass is this app's own
# ApplicationController, `include Kiosk::Handler` is the whole contract, and a
# macro is claimed by the NEXT `def` — a method with no macros above it is a
# helper the wire cannot see. `kind :query` puts a declaration on `GET`, and the
# kind belongs to the DECLARATION, not the class (K-921).
#
# NOT ROUTABLE: config/routes.rb draws nothing here. Handlers are reached only
# through the wire, where authentication, the registration PoW gate and the
# GUC-scoped transaction live; a route drawn straight here would bypass all
# three, and the mixin answers such a request 404.
class Kiosk::FrontDeskController < ApplicationController
  include Kiosk::Handler

  # salons — the full catalogue; no per-user scoping, any authenticated principal
  # may browse. ADR-0023: the description carries semantics only.
  kind :query
  description "Browse the public salon catalogue — every salon this front desk books for. Once the " \
              "human picks one, `book_appointment` takes it from there."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The whole salon catalogue.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    salon_id: { type: "integer", description: "Pass to book_appointment as `salon_id`." },
                    name:     { type: "string", description: "Salon name." },
                  },
                  required: %w[salon_id name],
                }
  def salons
    # `pluck` rather than loading models: naming the columns keeps the wire's
    # field names and their order a decision this handler makes (K-654).
    render json: Salon.order(:id).pluck(:id, :name).map { |id, name|
      { salon_id: id, name: name }
    }
  end

  # service_menu — the public menu with EUR prices; any authenticated principal
  # may read it to pick a service_id before booking.
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

  # availability — EVERGREEN (K-446): capacity is infinite and nothing goes
  # stale, so availability IS the service menu with every row `open: true`.
  kind :query
  description "Browse the salon's OPEN services. Every service on the menu is always bookable — this " \
              "salon is evergreen and has no finite capacity, so it never fills up and a booking never " \
              "fails for want of room. Takes no arguments. Once the human picks a row, " \
              "`book_appointment` books it and captures its price on the appointment."
  input_schema type: "object",
               additionalProperties: false,
               properties: {},
               required: []
  # service_menu's projection under this verb's own field names, plus `open`. The
  # two verbs stay separate because their CONTRACTS differ, not their query.
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

  # my_appointments — scoped by the session GUC: the agent supplies no filter.
  # `owned_by_current_principal` stays SQL-side — see Appointment (K-654).
  kind :query
  description "List this principal's appointments (scoped to authenticated user via kiosk.current_user_id())"
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # `id` here for the value book_appointment calls `appointment_id` — published
  # behaviour, named in the schema so an assistant reads it rather than meets it.
  output_schema type: "array",
                description: "The principal's appointments, oldest id first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    id:       { type: "string", description: "uuid — the appointment. book_appointment calls the same value `appointment_id`." },
                    salon_id: { type: "integer", description: "The salon booked." },
                    slot:     { type: "string", description: "Appointment time, ISO 8601." },
                  },
                  required: %w[id salon_id slot],
                }
  def my_appointments
    render json: Appointment.owned_by_current_principal
                            .order(:id)
                            .pluck(:id, :salon_id, :slot)
                            .map { |id, salon_id, slot|
                              { id: id, salon_id: salon_id, slot: slot }
                            }
  end

  # salon_calendar — STAFF forecast, role-gated on kiosk.current_role(), the GUC
  # set from the token's role claim (the bound human's IdP role):
  #
  #   owner → the WHOLE book, every visitor's bookings, plus a FORECAST summary
  #           SUMMED from those bookings' captured prices.
  #   any other role → ONLY their own bookings, and no forecast.
  #
  # Un-bypassable: the role rides the token, not the request args, and the WHERE
  # is provider-controlled. The gate reads the GUC rather than the mixin's
  # `kiosk_identity` so the scoping predicate and the branch agree by
  # construction, and so the query still works outside a wire request (an RLS
  # journey test), where kiosk_identity is nil but the GUCs are set anyway.
  #
  # `reach :role` — ADR-0028's third declared departure and the only verb in the
  # fleet carrying it: an `owner` reads EVERY principal's appointments. Sound only
  # because a role is ASSIGNED by the operator and never client-requested
  # (spec §5.4; the `privilege_self_selection` red-team scenario proves it).
  kind :query
  reach :role
  description "Staff forecast — role-gated: owner sees ALL bookings + a FORECASTED € revenue total (summed from the actual bookings' prices, growing from €0 as visitors book); any other role sees only their own bookings and no forecast (role from the bound human's IdP)"
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # TWO ROW SHAPES IN ONE ARRAY, discriminated by the field each has that the
  # other does not: `kind: "booking"` versus `summary: "forecast"`. The forecast
  # is APPENDED to the bookings rather than sitting beside them in an envelope. A
  # non-owner never sees the second shape — the role gate, not a format option.
  output_schema type: "array",
                description: "The bookings this caller may see, slot-ordered; for an owner, a forecast row after them.",
                items: {
                  oneOf: [
                    { type: "object", additionalProperties: false,
                      description: "One booking.",
                      properties: {
                        id:          { type: "string", description: "uuid — the appointment." },
                        salon_id:    { type: "integer", description: "The salon booked." },
                        slot:        { type: "string", description: "Appointment time, ISO 8601." },
                        service_id:  { type: %w[integer null], description: "The booked service, or null for a bare salon booking." },
                        service:     { type: %w[string null], description: "The booked service's name, or null." },
                        price_cents: { type: %w[integer null], description: "EUR cents CAPTURED on the booking, or null when no service was booked." },
                        kind:        { const: "booking", description: "booking — this row is an appointment." },
                        currency:    { type: "string", description: "EUR." },
                        price_eur:   { type: "string", description: "The captured price rendered for a human; \"€0\" when none was captured." },
                      },
                      required: %w[id salon_id slot service_id service price_cents kind currency price_eur] },
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
  def salon_calendar
    role = Appointment.current_principal_role

    book = role == "owner" ? Appointment.all : Appointment.owned_by_current_principal

    # `left_joins` because a bare salon booking carries no service: the row must
    # still appear, with a null service and a null captured price.
    appt_rows = book.left_joins(:service)
                    .order(:slot)
                    .pluck("appointments.id", "appointments.salon_id", "appointments.slot",
                           "appointments.service_id", "services.name", "appointments.price_cents")
                    .map { |id, salon_id, slot, service_id, service, price_cents|
                      { id: id, salon_id: salon_id, slot: slot, service_id: service_id,
                        service: service, price_cents: price_cents,
                        kind: "booking", currency: "EUR",
                        price_eur: Service.format_eur(price_cents) }
                    }

    rows = appt_rows

    # Owner-only FORECAST: summed live from the real per-booking prices, so it is
    # €0 before any booking and grows with each one — never a fixed number.
    if role == "owner"
      booked_cents = appt_rows.sum { |r| r[:price_cents].to_i }
      rows += [{
        summary:        "forecast",
        bookings:       appt_rows.size,
        currency:       "EUR",
        forecast_cents: booked_cents,
        forecast_eur:   Service.format_eur(booked_cents),
      }]
    end

    render json: rows
  end
end
