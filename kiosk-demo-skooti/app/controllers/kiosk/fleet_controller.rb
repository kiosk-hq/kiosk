# frozen_string_literal: true

# skooti's READ surface: the three verbs an assistant reaches with
# `GET /kiosk/<query-name>`, one endpoint per verb, arguments in the query
# string (protocol 0.4 deleted the multiplexed `POST /kiosk/query`). Kiosk
# ships a MIXIN, not a base class — `include
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
  # ── THE RECONCILIATION SURFACE (K-853) ────────────────────────────────────
  # This is the "per-user query" protocol.md §11.6 sends an assistant to after a
  # `pay` whose response it never read, so what it publishes about money is a
  # normative matter, not a convenience. Until K-853 it published NOTHING about
  # money: an assistant reconciling a lost `pay` learned only that a reservation
  # existed and was still `reserved`, which is not an answer — and the rental
  # verbs' payment gate read the settlement row alone, so it answered "no
  # settlement" about a ride that had already been charged.
  #
  # `payment_state` is the fix and it is a TRI-state on purpose: §11.6 requires
  # a third answer distinct from paid and not-paid, because "no record" is not
  # evidence that no money moved. See {Reservation.payment_state}.
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
    #
    # The settled flag is a CORRELATED EXISTS over the CALLER's settlements —
    # one statement for the whole list, not one query per row — and it is only
    # the second of the two witnesses {Reservation.payment_state} weighs.
    reservations = Reservation.arel_table
    settled_flag = Reservation.settled_flag(Settlement.of_current_principal)
    render json: Reservation.owned_by_current_principal
                            .joins(:scooter)
                            .order(reservations[:created_at].desc)
                            .pluck(reservations[:id], Scooter.arel_table[:code], reservations[:status],
                                   reservations[:payment_status], settled_flag)
                            .map { |id, scooter_code, status, payment_status, settled|
                              { reservation_id: id,
                                scooter_code:   scooter_code,
                                status:         status,
                                payment_state:  Reservation.payment_state(payment_status, settled) }
                            }
  end

  # ── kyc_status — poll a request_kyc verification the caller opened.
  #
  # THE CADENCE AND THE GIVE-UP HORIZON ARE PART OF THE CONTRACT (K-477/K-595,
  # K-606). The wire has no server→assistant push, so completion is learned by
  # re-polling this verb and nothing else; a descriptor that says "poll until
  # the human acts" and stops there leaves an agent to invent a loop with no
  # exit. The schedule below is QUOTED from kiosk.tech/skill.md rather than
  # invented here, so the two surfaces an assistant reads cannot publish rival
  # arithmetic, and `demo:schema` asserts that the SERVED descriptor still
  # carries both numbers.
  description "Poll a verification `request_kyc` opened, until the human has acted on it. Three " \
              "answers: still waiting; APPROVED, carrying the broker's signed attestation, which you " \
              "submit to `POST <endpoint>/agents/kyc` before asking for the motorcycle again; and " \
              "DECLINED, which is terminal. " \
              "POLLING: while your human is completing the check, re-check every ~5 seconds for the " \
              "first minute, then every ~15 seconds, and GIVE UP after about 10 minutes — an identity " \
              "check can legitimately take that long, but if it is still waiting by then, stop and " \
              "tell your human it is not done rather than polling indefinitely. A verification stays " \
              "pollable, so you can come back to it later; if the human's link has expired since, " \
              "start a new one."
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
