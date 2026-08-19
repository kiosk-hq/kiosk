# frozen_string_literal: true

# skooti's READ surface: the three verbs an assistant reaches with
# `POST /kiosk/query`. Kiosk ships a MIXIN, not a base class — `include
# Kiosk::Query` is the whole contract — and each class-level macro records a
# declaration that the NEXT `def` claims, so a method with no macros above it is
# a helper the wire cannot see.
#
# THE SUPERCLASS IS `ActionController::API`, and that is a decision rather than
# an omission — hoteling's, applied here for the same reason it applied there.
# skooti is `config.api_only = true` with no Devise and no `ApplicationController`
# at all; introducing one would add a cross-demo lockstep file whose sibling
# copies exist only for a human sign-in page this app does not serve. The mixin
# explicitly leaves the base class to the operator (K-495), and `HomeController`
# already names its own (`ActionController::Base`, for the HTML landing page).
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the five write verbs live next door in
# Kiosk::RentalsController. What the two halves share is their refusal
# vocabulary: {WireArguments} (which renders nothing, so the Operations use it
# too) and {KioskRefusals}.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate and the GUC-scoped transaction live. A route drawn straight here would
# bypass all three, and the mixin answers such a request 404.
class Kiosk::FleetController < ActionController::API
  include Kiosk::Query
  include KioskRefusals

  # ── scooters_available — the public fleet catalogue. No per-principal
  # scoping: every authenticated agent may browse what is available.
  description "Browse the available fleet — each row carries the vehicle's name and pickup dock/location " \
              "so you can pick one by name or nearest dock. needs_licence flags the KYC-gated combustion " \
              "motorcycle (rent it via rent_motorcycle); licence-free scooters use start_rental. " \
              "price_per_min_cents is EUR cents per minute — carts must be signed in eur at the operator-quoted total. " \
              "Takes no parameters and returns the whole available fleet (small; not paginated); reference a " \
              "vehicle by its `code` (e.g. \"SK-001\") when reserving."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # `lat`/`lng` are `numeric(10,6)` columns, so ActiveRecord hands back a
  # BigDecimal and Rails renders a BigDecimal as a JSON **string** — the wire
  # really does carry `"52.3739"`, not `52.3739`. The example below said
  # otherwise until this schema was written from the handler rather than from
  # the description; an assistant that trusted it would have fed a string to
  # arithmetic. Both are nullable columns.
  output_schema type: "array",
                description: "The whole available fleet, small and not paginated.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    code:                { type: "string", description: "The ONLY vehicle handle on the wire — pass it to reserve as `scooter_code`." },
                    name:                { type: %w[string null], description: "The vehicle's given name, or null." },
                    dock:                { type: %w[string null], description: "Pickup dock/location, or null." },
                    status:              { type: "string", description: "available — this verb lists only what is." },
                    kind:                { type: "string", description: "scooter | motorcycle." },
                    needs_licence:       { type: "boolean", description: "True for the KYC-gated combustion motorcycle: rent it with rent_motorcycle, not start_rental." },
                    lat:                 { type: %w[string null], description: "Latitude as a decimal STRING (e.g. \"52.3739\"), or null." },
                    lng:                 { type: %w[string null], description: "Longitude as a decimal STRING (e.g. \"4.8809\"), or null." },
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
    # `pluck` rather than loading models: this is a projection, and naming the
    # columns is what keeps the wire's field names AND THEIR ORDER a decision
    # this handler makes rather than a side effect of the schema.
    #
    # `code` is the ONLY vehicle handle on the wire — reserve takes
    # scooter_code. The numeric primary key is deliberately NOT selected: a row
    # id no verb accepts is a dead field that invites the assistant to guess it
    # is some verb's param (K-516, and K-484 for the same defect on atablefor;
    # descriptor-house-style.md "Never expose a row id that no verb consumes").
    # It still ORDERS the fleet — an ORDER BY needs no SELECT, and `order(:id)`
    # says so without putting the column in the projection.
    #
    # The pricing currency is advertised on every row so an external assistant
    # knows to sign its cart in EUR (the cashier check rejects any other
    # currency at capture). It is appended last, exactly where the old
    # `rows.each` put it.
    render json: Scooter.available
                        .order(:id)
                        .pluck(:code, :name, :dock, :status, :kind, :needs_licence,
                               :lat, :lng, :price_per_min_cents)
                        .map { |code, name, dock, status, kind, needs_licence, lat, lng, cents|
                          { code:                code,
                            name:                name,
                            dock:                dock,
                            status:              status,
                            kind:                kind,
                            needs_licence:       needs_licence,
                            lat:                 lat,
                            lng:                 lng,
                            price_per_min_cents: cents,
                            currency:            "eur" }
                        }
  end

  # ── my_reservations — per-principal: the caller's OWN reservations only. The
  # caller supplies no filter; the scope is provider-controlled and
  # un-bypassable. `owned_by_current_principal` is the ONE place the identity
  # predicate is written — see Reservation for why it stays SQL-side.
  description "List this principal's scooter reservations (scoped to authenticated user via kiosk.current_user_id()). " \
              "Each row carries a `reservation_id`; pass it to start_rental / rent_motorcycle as `reservation_id`. " \
              "Each row also carries the vehicle's `scooter_code` — the same handle scooters_available shows and reserve takes."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The principal's reservations, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    reservation_id: { type: "string", description: "uuid. Pass to start_rental / rent_motorcycle as `reservation_id`." },
                    scooter_code:   { type: "string", description: "The vehicle's `code` — the same handle scooters_available shows and reserve takes." },
                    status:         { type: "string", description: "reserved | active." },
                  },
                  required: %w[reservation_id scooter_code status],
                }
  def my_reservations
    # The vehicle is identified by its `code`, never by the numeric scooters.id:
    # that primary key is not a param of any verb, so emitting it would be a
    # dead field the assistant can only guess at (K-516 sweep). The join turns
    # the dead internal key into the live handle instead of dropping the vehicle
    # from the row.
    #
    # Every column is named through its OWN arel_table. Both tables carry `id`,
    # `status` and `created_at`, so an unqualified `:status` would be resolved
    # by ActiveRecord rather than by this handler — and which table it picked
    # would be invisible here, which is not a thing to leave to a resolution
    # rule in a row an assistant acts on.
    #
    # `created_at DESC` with no tiebreaker is what this verb has always ordered
    # by, and it is kept rather than quietly improved.
    reservations = Reservation.arel_table
    render json: Reservation.owned_by_current_principal
                            .joins(:scooter)
                            .order(reservations[:created_at].desc)
                            .pluck(reservations[:id], Scooter.arel_table[:code], reservations[:status])
                            .map { |id, scooter_code, status|
                              { reservation_id: id, scooter_code: scooter_code, status: status }
                            }
  end

  # ── kyc_status — poll a request_kyc verification the caller opened.
  description "Poll a request_kyc verification by its request_id. Returns {status: \"pending\"} until the " \
              "human acts; {status: \"approved\", kyc_jws} once approved (submit the kyc_jws to " \
              "POST /kiosk/agents/kyc, then retry rent_motorcycle); {status: \"declined\"} if declined."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 request_id: { type: "string",
                               description: "The verification to poll — the `request_id` request_kyc returned." },
               },
               required: ["request_id"]
  # A ONE-ROW array: this is a query and a query answers with rows. The two
  # shapes are the two states, and `kyc_jws` exists only in the approved one —
  # there is nothing to hand back before the human acts, and nothing to leak.
  output_schema type: "array",
                description: "Exactly one row: the verification's current state.",
                minItems: 1, maxItems: 1,
                items: {
                  oneOf: [
                    { type: "object", additionalProperties: false,
                      description: "Not yet approved.",
                      properties: { status: { enum: %w[pending declined],
                                              description: "pending = the human has not acted; declined is terminal." } },
                      required: ["status"] },
                    { type: "object", additionalProperties: false,
                      description: "Approved — the signed attestation is here.",
                      properties: {
                        status:  { const: "approved", description: "approved." },
                        kyc_jws: { type: "string", description: "A full compact JWS. Submit the ENTIRE value to POST /kiosk/agents/kyc, then retry rent_motorcycle." },
                      },
                      required: %w[status kyc_jws] },
                  ],
                }
  def kyc_status
    return render_refusal(WireArguments.missing("request_id")) if params[:request_id].blank?

    # Bound to the caller by `owned_by_current_principal`, so an agent only ever
    # sees the status (and the jws) of a request IT opened. `pick`, not
    # `find_by!` — the bang form raises RecordNotFound, which Rails maps to 404
    # and the mixin's `rescue_from` floor would render, i.e. the same status this
    # handler answers but with Rails' message instead of the operator's.
    row = KycVerificationRequest.owned_by_current_principal
                                .where(request_token: params[:request_id].to_s)
                                .pick(:status, :kyc_jws)
    if row.nil?
      return render_refusal(OperationResult.refused(
        code: "not_found", message: "no such verification request for this principal",
      ))
    end

    status, kyc_jws = row
    # A ONE-ROW array: this is a query, and a query answers with rows. The jws
    # travels only once the human has approved — there is nothing to hand back
    # before that, and nothing to leak.
    render json: (status == KycVerificationRequest::APPROVED ?
                    [{ status: status, kyc_jws: kyc_jws }] :
                    [{ status: status }])
  end
end
