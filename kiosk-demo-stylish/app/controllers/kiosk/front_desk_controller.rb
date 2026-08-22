# frozen_string_literal: true

# stylish's READ surface: the five verbs an assistant reaches with
# `GET /kiosk/<query-name>` — one endpoint each, arguments in the query string.
# Kiosk ships a MIXIN, not a base class — the superclass is this app's own
# ApplicationController, and `include Kiosk::Handler` is the whole contract. Each
# class-level macro records a declaration and the NEXT `def`
# claims it, so a method with no macros above it is a helper the wire cannot see.
#
# `kind :query` above each declaration is what puts it on `GET`; the kind
# belongs to the DECLARATION, not to the class (K-921), so ONE controller may
# declare both. Keeping the read and the write halves in separate classes is
# this demo's shape, not a rule. The write half lives next door in
# Kiosk::AppointmentsController. Nothing here is shared with it: the only logic
# both sides need is EUR formatting, which is a Service model method
# (Service.format_eur) and was never controller code.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate and the GUC-scoped transaction live. A route drawn straight here
# would bypass all three, and the mixin answers such a request 404.
class Kiosk::FrontDeskController < ApplicationController
  include Kiosk::Handler

  # salons — full salon catalogue; no per-user scoping, any authenticated
  # principal may browse (mirrors the public SELECT policy previously in RLS).
  # ADR-0023: semantics only — no "pass X to Y as `z`" tail. `output_schema`
  # names the row's fields and points the identifying one at the verb that takes
  # it; naming the follow-on VERB here is the sanctioned form.
  kind :query
  description "Browse the public salon catalogue — every salon this front desk books for, in one " \
              "answer rather than a page of it. Once the human picks one, `book_appointment` takes it " \
              "from there."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
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
    # `pluck` rather than loading models: this is a projection, and naming the
    # columns is what keeps the wire's field names and their order a decision
    # this handler makes rather than a side effect of the schema (K-654).
    render json: Salon.order(:id).pluck(:id, :name).map { |id, name|
      { salon_id: id, name: name }
    }
  end

  # service_menu — the salon's public service menu with EUR prices. Any
  # authenticated principal may read it; an assistant uses it to pick a
  # service_id (and see the € price) before booking.
  kind :query
  description "Browse the salon's service menu, priced. Takes no arguments and returns the WHOLE " \
              "menu rather than a page of it (small; not paginated), so an empty answer would mean the " \
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

  # availability — the salon's EVERGREEN availability (K-446). Every service on
  # the menu is ALWAYS bookable: infinite capacity, overbooking allowed, nothing
  # to fill up or go stale, no reseed cron. So availability IS the service menu,
  # every row flagged `open: true`. Any authenticated principal (a visitor's
  # assistant) reads it to pick a service to book. Each row carries a `service_id`
  # — pass it to book_appointment to book that service (its EUR price is captured).
  kind :query
  description "Browse the salon's OPEN services. Every service on the menu is always bookable — this " \
              "salon is evergreen and has no finite capacity, so it never fills up and a booking never " \
              "fails for want of room. Takes no arguments. Once the human picks a row, " \
              "`book_appointment` books it and captures its price on the appointment."
  input_schema type: "object",
               additionalProperties: false,
               properties: {},
               required: []
  # The same projection as service_menu under this verb's own field names —
  # `service` rather than `name`, plus the evergreen `open`. The two verbs stay
  # separate because their CONTRACTS differ, not their query, and these two
  # schemas are where that difference is now readable without calling both.
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
    # Same projection as service_menu, published under this verb's own field
    # names (`service`, plus the evergreen `open: true`) — the two verbs stay
    # separate because their CONTRACTS differ, not their query.
    render json: Service.order(:price_cents).pluck(:id, :name, :price_cents)
                        .map { |id, name, price_cents|
                          { service_id: id, service: name, price_cents: price_cents,
                            open: true, currency: "EUR",
                            price_eur: Service.format_eur(price_cents) }
                        }
  end

  # my_appointments — per-user appointment list scoped by the session GUC.
  # App-layer isolation: the agent supplies no filter; the scope is
  # provider-controlled and cannot be bypassed by the caller.
  # `owned_by_current_principal` is ONE of the two places this demo writes the
  # identity predicate — see Appointment for why it stays SQL-side (K-654).
  kind :query
  description "List this principal's appointments (scoped to authenticated user via kiosk.current_user_id())"
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # `id`, not `appointment_id`, and that is published behaviour rather than an
  # inconsistency this declaration gets to tidy away — book_appointment answers
  # `appointment_id` for the same value. Named here so an assistant reads the
  # mismatch off the schema instead of meeting it.
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

  # salon_calendar — STAFF forecast, role-gated (roles-from-IdP).
  # Reads kiosk.current_role() (the GUC set from the token's role claim, which a
  # staff assistant inherited from the bound human's IdP role):
  #
  #   owner → the WHOLE book: every booking made so far (across all visitors),
  #           plus a FORECAST summary — the € revenue SUMMED from those bookings'
  #           captured prices. Starts at €0 and grows as visitors book.
  #   any other role (customer, or none) → ONLY their OWN bookings
  #           (rows WHERE user_id = kiosk.current_user_id()), and NO forecast.
  #
  # The gate is un-bypassable: an agent can neither self-select `owner` at binding
  # nor pass a wider filter — the role rides the token (from the bound human's
  # IdP), not the request args, and the WHERE is provider-controlled. The forecast
  # is computed live from the real per-booking prices — never a hardcoded number.
  #
  # The gate reads the GUC rather than the mixin's `kiosk_identity`, and
  # deliberately stays that way: the scoping predicate and the branch then agree
  # by construction, and the query keeps working when it is reached outside a wire
  # request (an RLS journey test), where kiosk_identity is nil but the four GUCs
  # are set regardless. K-654 moved the read itself into
  # `Appointment.current_principal_role` — this handler writes no SQL — and
  # retired the part that was indefensible: `appt_scope` used to be a WHERE
  # clause BUILT as a Ruby string and spliced into `execute`, which is the exact
  # idiom a reader would copy into a query that does take caller input. The
  # branch now picks between two relations.
  # `reach :role` — the third of ADR-0028's declared departures, and the only
  # verb in the fleet that carries it. An `owner` reads EVERY principal's
  # appointments (`Appointment.all`, one line down); every other role reads its
  # own. Under §7.2's old unconditional wording that was a violation of the
  # spec's strongest sentence hiding inside a feature; it is now a published
  # claim about the verb. It is sound only because a role is ASSIGNED by the
  # operator and is never client-requested (spec §5.4, and this demo's own
  # `privilege_self_selection` red-team scenario is what proves it) — an origin
  # that let a caller name its own role would have made this a self-service
  # escalation instead of an authorization model.
  kind :query
  reach :role
  description "Staff forecast — role-gated: owner sees ALL bookings + a FORECASTED € revenue total (summed from the actual bookings' prices, growing from €0 as visitors book); any other role sees only their own bookings and no forecast (role from the bound human's IdP)"
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # TWO ROW SHAPES IN ONE ARRAY, and the discriminator is the field each one
  # has that the other does not: a booking carries `kind: "booking"`, the
  # owner-only trailer carries `summary: "forecast"`. That is what the handler
  # renders — the forecast is APPENDED to the booking rows rather than sitting
  # beside them in an envelope — so the schema declares the union rather than
  # pretending the array is homogeneous. A non-owner never sees the second
  # shape at all, which is the role gate, not an option of the format.
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

    # owner → the whole book; anyone else → only their own bookings.
    book = role == "owner" ? Appointment.all : Appointment.owned_by_current_principal

    # BOOKINGS made so far (accumulate as visitors book — zero at the start).
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

    # Owner also gets a FORECAST summary: the € revenue summed from the real
    # per-booking prices. A live figure from real rows — not a fixed number; it is
    # €0 before any booking and grows with each one.
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
