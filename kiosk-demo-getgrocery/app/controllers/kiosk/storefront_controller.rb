# frozen_string_literal: true

# getgrocery's READ surface: the four verbs an assistant reaches with
# `GET /kiosk/<query-name>`, arguments in the query string. Kiosk ships a
# MIXIN, not a base class — `include
# Kiosk::Query` is the whole contract — and each class-level macro records a
# declaration that the NEXT `def` claims, so a method with no macros above it is
# a helper the wire cannot see.
#
# THE SUPERCLASS IS `ActionController::API`, and that is a decision rather than
# an omission — hoteling's, applied here for the same reason it applied there
# and on skooti. getgrocery has no `ApplicationController` at all; introducing
# one would add a cross-demo lockstep file whose sibling copies exist only for a
# human sign-in page this app does not serve. The mixin explicitly leaves the
# base class to the operator (K-495), and the two HTML surfaces this app DOES
# serve — `HomeController` and `Admin::OrdersController` — already name their own
# (`ActionController::Base`, because they render views).
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the four write verbs live next door in
# Kiosk::OrdersController. What the two halves share is their argument
# vocabulary: an address is checked against the served Dublin districts by
# `delivery_slots` here and by both order verbs there, word for word. The shape
# guard for that is {WireArguments} (which renders nothing, so the Operations use
# it too) and the rendering of a refusal is {KioskRefusals}.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate, the declared-input_schema check and the GUC-scoped transaction live.
# A route drawn straight here would bypass all four, and the mixin answers such a
# request 404.
class Kiosk::StorefrontController < ActionController::API
  include Kiosk::Query
  include KioskRefusals

  # ── catalog — the public shelf. No per-principal scoping: every
  # authenticated agent browses the same in-stock catalogue.
  description "Browse in-stock products from the getgrocery catalog (out-of-stock items are hidden). " \
              "All prices are EUR cents — carts must be signed in eur at these exact prices. " \
              "Takes no parameters and returns the whole in-stock catalogue (small; not paginated); " \
              "each row carries the stable `sku` (reference products by sku, never the numeric id), a " \
              "`low` flag when stock is running out, and an `age_restricted` flag on alcohol — an " \
              "age_restricted item can only be ORDERED (create_order) by an agent that has completed an " \
              "18+ anonymized-KYC check (run request_kyc first); non-restricted items need no KYC."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # A bare array — the whole in-stock shelf, name-ordered, not paginated.
  # `low` and `age_restricted` are OPTIONAL by construction: the handler appends
  # each only when it is true, because publishing `false` on every ordinary
  # grocery would be noise in the largest catalogue in the fleet. So an ABSENT
  # flag means false, which is what the `required` list below says.
  output_schema type: "array",
                description: "In-stock products, name-ordered.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    sku:            { type: "string", description: "The stable product handle — reference products by this, never by a numeric id." },
                    name:           { type: "string", description: "Display name." },
                    price_cents:    { type: "integer", description: "EUR cents. Sign carts at exactly this price." },
                    price_eur:      { type: "string", description: "The same price rendered for a human, e.g. \"€4.49\"." },
                    currency:       { type: "string", description: "eur." },
                    low:            { type: "boolean", description: "Present and true only when stock is running out; absent means it is not." },
                    age_restricted: { type: "boolean", description: "Present and true only on alcohol, which create_order accepts only after an 18+ KYC check; absent means unrestricted." },
                  },
                  required: %w[sku name price_cents price_eur currency],
                }
  example_params({})
  example_row({
    sku: "sourdough-bread", name: "Sourdough Bread", price_cents: 449,
    price_eur: "€4.49", currency: "eur",
  })
  def catalog
    # `pluck` rather than loading models: this is a projection, and naming the
    # columns is what keeps the wire's field names AND THEIR ORDER a decision
    # this handler makes rather than a side effect of the schema. `sku` is the
    # only product handle on the wire — the numeric primary key is deliberately
    # not selected: a row id no verb accepts is a dead field that invites the
    # assistant to guess it is some verb's param.
    #
    # `low` and `age_restricted` are appended CONDITIONALLY, exactly where the
    # old `rows.map` put them: a row without the flag is a row the flag is not
    # true of, and publishing `false` for every ordinary grocery would be noise
    # in the largest catalogue in the fleet.
    render json: Product.in_stock
                        .order(:name)
                        .pluck(:sku, :name, :price_cents, :stock, :age_restricted)
                        .map { |sku, name, price_cents, stock, age_restricted|
                          row = { "sku"         => sku,
                                  "name"        => name,
                                  "price_cents" => price_cents,
                                  "price_eur"   => Product.format_eur(price_cents),
                                  "currency"    => "eur" }
                          row["low"] = true if Product.low_stock?(stock)
                          # Advertise the 18+ gate so an assistant knows to complete
                          # anonymized KYC (request_kyc) BEFORE it tries to order this
                          # item. Read through the same fail-closed predicate
                          # create_order enforces with, so the shelf and the gate
                          # cannot come to disagree about one row.
                          row["age_restricted"] = true if Product.age_restricted?(age_restricted)
                          row
                        }
  end

  # ── delivery_slots — the still-bookable windows for a date at an IN-ZONE
  # Dublin address. Touches no table at all: the windows are a function of the
  # date and the operator's locale ({DeliverySlots}), and the address is a
  # function of the served districts ({DublinZones}).
  description "Get available delivery time slots for a date at a Dublin delivery address. " \
              "delivery_address is REQUIRED and must be an in-zone Dublin address (a postal " \
              "district — e.g. \"42 Camden Street, Dublin 2\" or an Eircode like \"D02 XY45\"). " \
              "getgrocery routes by district and delivers only within its served Dublin zones; " \
              "an out-of-zone or district-less address returns 400 (bad_request) naming what is " \
              "needed. Obtain the real address from your human FIRST — the same address is required " \
              "again at create_order. NOTE: the operator validates format + zone only; it cannot " \
              "verify a plausible in-zone address is real, so confirm it with your human. " \
              "Each row carries a `delivery_slot_id` (and its `date`); pass both to create_order " \
              "as `delivery_slot_id` and `delivery_date`."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 date:             { type: "string", description: "Delivery date, YYYY-MM-DD." },
                 delivery_address: { type: "string", description: "Dublin delivery address naming a served postal district." },
               },
               required: ["date", "delivery_address"]
  # A bare array of the still-bookable windows for that date. EMPTY is an
  # honest answer here and only here: every one of today's windows may already
  # have begun, in which case the earliest bookable slot is on a later date.
  output_schema type: "array",
                description: "The still-bookable delivery windows for the requested date and zone.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    delivery_slot_id: { type: "integer", description: "Pass to create_order as `delivery_slot_id`." },
                    date:             { type: "string", description: "YYYY-MM-DD — pass to create_order as `delivery_date` so the booking lands on the day you saw." },
                    slot_at:          { type: "string", description: "The window's start instant, ISO 8601 with offset." },
                    label:            { type: "string", description: "The window rendered for a human, e.g. \"08:00–10:00\"." },
                    zone:             { type: "string", description: "The served Dublin postal district the address routed to." },
                  },
                  required: %w[delivery_slot_id date slot_at label zone],
                }
  example_params({ date: "2026-08-10", delivery_address: "42 Camden Street, Dublin 2" })
  example_row({ delivery_slot_id: 1, date: "2026-08-10", slot_at: "2026-08-10T08:00:00+01:00",
                label: "08:00–10:00", zone: "D02" })
  def delivery_slots
    # `params.key?` and not `blank?`: this verb asked `params.fetch(:date) { … }`,
    # so an ABSENT date is "missing param: date" while a date that is present and
    # null or empty falls through to the parser and is "invalid date: ". That is
    # a question about the request ENVELOPE, and the controller is the only place
    # it can be asked.
    return render_refusal(missing_param("date")) unless params.key?(:date)

    # ADDRESS-UPFRONT (K-468): the delivery address is a REQUIRED early input,
    # checked BEFORE the date. This is what forces the assistant to obtain the
    # address from its human before it can even see slots.
    return render_refusal(WireArguments.missing_address) if params[:delivery_address].blank?

    zone, zone_refusal = WireArguments.served_zone(params[:delivery_address])
    return render_refusal(zone_refusal) if zone_refusal

    date = begin
      Date.parse(params[:date].to_s)
    rescue ArgumentError, TypeError
      return render_refusal(OperationResult.refused(
        code: "bad_request", message: "invalid date: #{params[:date]}",
      ))
    end

    # PAST-SLOT FILTER (K-480): return ONLY still-bookable windows. For TODAY,
    # drop any slot whose start has already passed in the operator's locale
    # (Dublin); future dates keep all slots. If every one of today's slots has
    # begun, this is legitimately empty and the earliest bookable slot is on a
    # later date — the assistant simply should not see an un-bookable 08:00–10:00
    # window at 11:00. `date` on each row (K-470) is what create_order books.
    render json: DeliverySlots.bookable_ids(date).map { |slot_id|
      slot_time = DeliverySlots.slot_at(date, slot_id)
      hour      = slot_time.hour
      { "delivery_slot_id" => slot_id,
        "date"    => date.iso8601,
        "slot_at" => slot_time.iso8601,
        "label"   => "#{hour.to_s.rjust(2, "0")}:00–#{(hour + DeliverySlots::WINDOW_HOURS).to_s.rjust(2, "0")}:00",
        "zone"    => zone }
    }
  end

  # ── my_orders — per-principal: the caller's OWN orders only. The caller
  # supplies no filter; the scope is provider-controlled and un-bypassable.
  description "List this principal's orders with delivery slot, address, and a paid flag (scoped to authenticated user via kiosk.current_user_id()). Each row carries an `order_id`; pass it to reschedule_delivery (or create_order to replace an unpaid order) as `order_id`. Use the `paid` flag as a settlement lookup: after a pay whose response you did not receive, re-read my_orders and only retry pay if the order is still unpaid (K-545)."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # A bare array, newest first. `slot_at` and `address` are the two nullable
  # columns on `orders` and travel as null rather than being dropped, so the
  # row shape does not change with the order's completeness.
  output_schema type: "array",
                description: "The principal's orders, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    order_id:    { type: "string", description: "Pass to reschedule_delivery (or to create_order, to replace an unpaid order) as `order_id`." },
                    status:      { type: "string", description: "The operator's order status." },
                    total_cents: { type: "integer", description: "EUR cents." },
                    slot_at:     { type: %w[string null], description: "The booked delivery window's start instant, ISO 8601 with offset, or null." },
                    address:     { type: %w[string null], description: "The delivery address on the order, or null." },
                    paid:        { type: "boolean", description: "The settlement lookup: after a pay whose response you did not receive, re-read this and retry pay only if it is still false." },
                  },
                  required: %w[order_id status total_cents slot_at address paid],
                }
  def my_orders
    # `paid` is {Order.paid_flag} over the CALLER's settlements — the same
    # containment the operator's back office reads over ALL of them, which is
    # what makes the two surfaces one behaviour with two authorities rather than
    # two copies of one SQL string (see {Order.settling}).
    #
    # `created_at DESC` with no tiebreaker is what this verb has always ordered
    # by, and it is kept rather than quietly improved.
    render json: Order.owned_by_current_principal
                      .order(created_at: :desc)
                      .pluck(:id, :status, :total_cents, :slot_at, :address,
                             Order.paid_flag(Settlement.of_current_principal))
                      .map { |id, status, total_cents, slot_at, address, paid|
                        { "order_id"    => id,
                          "status"      => status,
                          "total_cents" => total_cents,
                          # `pluck` casts a timestamptz to an
                          # ActiveSupport::TimeWithZone, whose JSON rendering of a
                          # UTC instant is "…Z" where the raw driver's Time
                          # rendered "…+00:00". Same instant, different published
                          # spelling — and a conversion does not get to change
                          # what a field LOOKS like, so the offset form is
                          # restored rather than left to the type that happens to
                          # come back.
                          "slot_at"     => slot_at&.utc&.getlocal(0),
                          "address"     => address,
                          "paid"        => paid }
                      }
  end

  # ── kyc_status — poll a request_kyc verification the caller opened.
  description "Poll a request_kyc verification by its request_id. Returns {status: \"pending\"} until the " \
              "human acts; {status: \"approved\", kyc_jws} once approved (submit the kyc_jws to " \
              "POST /kiosk/agents/kyc, then retry create_order); {status: \"declined\"} if declined. " \
              "kyc_jws is a full compact JWS — a long, single-line, dot-separated token; submit the " \
              "ENTIRE value from this field, never a truncated console echo. " \
              "POLLING: while your human completes the verification, re-check every ~5 seconds for the " \
              "first minute, then every ~15 seconds, and GIVE UP after about 10 minutes — an identity " \
              "check can legitimately take that long, " \
              "but if it is still \"pending\" then, stop polling and tell your human it is not done yet " \
              "rather than polling indefinitely. The request_id stays pollable, so you can re-check later " \
              "(if the human's verification link has since expired, start a new request_kyc). " \
              "\"declined\" is TERMINAL: do not keep polling it — start a new request_kyc if the human " \
              "wants to try again."
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
                                              description: "pending = the human has not acted; declined is TERMINAL — start a new request_kyc instead of polling." } },
                      required: ["status"] },
                    { type: "object", additionalProperties: false,
                      description: "Approved — the signed attestation is here.",
                      properties: {
                        status:  { const: "approved", description: "approved." },
                        kyc_jws: { type: "string", description: "A full compact JWS. Submit the ENTIRE value to POST /kiosk/agents/kyc, then retry create_order." },
                      },
                      required: %w[status kyc_jws] },
                  ],
                }
  def kyc_status
    return render_refusal(WireArguments.missing("request_id")) if params[:request_id].blank?

    # Bound to the caller by `owned_by_current_principal`, so an agent only ever
    # sees the status — and the jws — of a request IT opened, and cannot poll (or
    # lift the attestation from) another agent's verification. `pick`, not
    # `find_by!`: the bang form raises RecordNotFound, which Rails maps to 404 and
    # the mixin's `rescue_from` floor would render — the same status this handler
    # answers, but with Rails' message instead of the operator's.
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
                    [{ "status" => status, "kyc_jws" => kyc_jws }] :
                    [{ "status" => status }])
  end

  private

  # `delivery_slots` says "missing PARAM" where every other verb on this origin
  # says "missing field", and that wording is published behaviour rather than an
  # inconsistency this conversion gets to tidy away.
  def missing_param(field)
    OperationResult.refused(code: "bad_request", message: "missing param: #{field}")
  end
end
