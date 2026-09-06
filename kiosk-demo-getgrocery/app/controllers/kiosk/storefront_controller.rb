# frozen_string_literal: true

# getgrocery's READ surface: the four verbs an assistant reaches with
# `GET /kiosk/<query-name>`, arguments in the query string. Kiosk ships a MIXIN,
# not a base class — `include Kiosk::Handler` is the whole contract — and each
# class-level macro records a declaration that the NEXT `def` claims, so a method
# with no macros above it is a helper the wire cannot see.
#
# THE SUPERCLASS IS `ActionController::API` by decision, not omission: the mixin
# leaves the base class to the operator, and getgrocery has no
# `ApplicationController` at all — the HTML surfaces it DOES serve name
# `ActionController::Base` themselves, because they render views.
#
# `kind :query` above each declaration is what puts it on `GET`; the kind belongs
# to the DECLARATION, not to the class, so splitting the read and write
# halves is this demo's shape rather than a rule. The write verbs live next door
# in Kiosk::OrdersController, and what the two halves share is their argument
# vocabulary — an address is checked against the served Dublin districts here and
# by both order verbs there, word for word — through {WireArguments} (which
# renders nothing, so the Operations use it too) and {KioskRefusals}.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate, the declared-input_schema check and the GUC-scoped transaction live.
# A route drawn straight here would bypass all four, and the mixin answers such a
# request 404.
class Kiosk::StorefrontController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals

  # ── catalog — the public shelf. No per-principal scoping: every authenticated
  # agent browses the same in-stock catalogue.
  kind :query
  description "Browse the getgrocery catalogue. Only what is IN STOCK appears — a sold-out product is " \
              "absent rather than listed as unavailable. Prices are EUR cents and a " \
              "cart is signed at exactly these, so re-read the shelf before paying rather than " \
              "trusting a price you cached. Two flags matter to an assistant: one marks a product " \
              "whose stock is running out, and one marks alcohol — which `create_order` accepts only " \
              "from an account that has already completed an 18+ anonymized-KYC check, and " \
              "`request_kyc` is what starts one. Nothing else on this shelf needs a check."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # `low` and `age_restricted` are OPTIONAL by construction: the handler appends
  # each only when true, because publishing `false` on every ordinary grocery
  # would be noise in the largest catalogue in the fleet. An ABSENT flag means
  # false, which is what the `required` list below says.
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
    # `pluck` rather than loading models: naming the columns keeps the wire's
    # field names AND THEIR ORDER a decision this handler makes rather than a
    # side effect of the schema. `sku` is the only product handle on the wire —
    # the numeric primary key is deliberately not selected, because a row id no
    # verb accepts invites the assistant to guess it is some verb's param.
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
                          # Advertise the 18+ gate so an assistant completes KYC
                          # BEFORE ordering. Read through the same fail-closed
                          # predicate create_order enforces with, so the shelf
                          # and the gate cannot disagree about one row.
                          row["age_restricted"] = true if Product.age_restricted?(age_restricted)
                          row
                        }
  end

  # ── delivery_slots — the still-bookable windows for a date at an IN-ZONE
  # Dublin address. Touches no table: the windows are a function of the date and
  # the operator's locale ({DeliverySlots}), the address of the served districts
  # ({DublinZones}).
  kind :query
  description "Get the delivery windows still bookable on a chosen day at a chosen Dublin address. " \
              "getgrocery routes by postal district and delivers only inside the Dublin zones it " \
              "serves, so an address it cannot place — outside those zones, or with no district in it " \
              "at all — is not servable, and neither is a day already gone. An EMPTY " \
              "array means every window on that day has already begun: try a later one. Get " \
              "the REAL address from your human before calling. The operator checks only its FORM and " \
              "its zone — it cannot tell a plausible in-zone address from a real one — and " \
              "`create_order` needs the same address again, so an invented one books a delivery to " \
              "nowhere."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 date:             { type: "string", format: "date",
                                     description: "OPTIONAL. Delivery date, YYYY-MM-DD. OMIT IT for " \
                                                  "the soonest day this shop can deliver -- you " \
                                                  "cannot compute that yourself, because the day " \
                                                  "rolls over in the shop's own locale and not in " \
                                                  "yours. Send one only when your human named a " \
                                                  "day. TODAY or later; an earlier date is refused " \
                                                  "with the earliest bookable one named. Every row " \
                                                  "carries the date it is for." },
                 delivery_address: { type: "string", description: "Dublin delivery address naming a served postal district." },
               },
               required: ["delivery_address"]
  # EMPTY is an honest answer here and ONLY here: every one of today's windows
  # may already have begun, in which case the earliest bookable slot is on a
  # later date. A date BEFORE today answers 400 instead.
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
  # THE DATE IS RESOLVED, NOT WRITTEN DOWN: a calendar literal is an
  # example that ages into a 400, since a date before today is REFUSED. These are
  # RESOLVABLE slots (see {Kiosk::Server::SchemaSlots}), so both name
  # {DeliverySlots.example_date} — tomorrow in the operator's own clock.
  example_params({ date:             -> { DeliverySlots.example_date.iso8601 },
                   delivery_address: "42 Camden Street, Dublin 2" })
  example_row({ delivery_slot_id: 1,
                date:    -> { DeliverySlots.example_date.iso8601 },
                slot_at: -> { DeliverySlots.slot_at(DeliverySlots.example_date, 1).iso8601 },
                label: "08:00–10:00", zone: "D02" })
  def delivery_slots
    # `date` IS OPTIONAL, AND OMITTING IT IS THE CORRECT CALL FOR "the soonest
    # you can deliver". The caller cannot compute this operator's today: it
    # delivers in Europe/Dublin, and between 23:00 and 00:00 UTC an assistant's
    # own date is a different day. Requiring the field made that gap the
    # CALLER's problem and there was no way for the caller to solve it -- it
    # would have to trust a timezone named in a description string, carry tzdata,
    # and still race the boundary. The operator knows its own date; so it uses it.
    #
    # A date that IS sent is still validated exactly as before, past dates
    # included, because "deliver on Friday" is a different request from "deliver
    # as soon as you can" and only the caller knows which one it is making.

    # ADDRESS-UPFRONT: checked BEFORE the date, which is what forces the
    # assistant to obtain the address from its human before it can see slots.
    return render_refusal(WireArguments.missing_address) if params[:delivery_address].blank?

    zone, zone_refusal = WireArguments.served_zone(params[:delivery_address])
    return render_refusal(zone_refusal) if zone_refusal

    # OMITTED means "the soonest day you can deliver", so an exhausted today is
    # not an answer -- it is the operator's job to step over it. Returning an
    # empty list here would hand the caller back the very problem it omitted the
    # date to avoid: it would have to work out the operator's tomorrow, which it
    # cannot do without the operator's locale.
    #
    # Only one step is needed: every window of a future day is still bookable,
    # so the day after today always has slots. A loop would suggest otherwise.
    unless params.key?(:date)
      soonest = DeliverySlots.now.to_date
      soonest += 1 if DeliverySlots.bookable_ids(soonest).empty?
      return render_slots(soonest, zone)
    end

    date = begin
      Date.parse(params[:date].to_s)
    rescue ArgumentError, TypeError
      return render_refusal(OperationResult.refused(
        code: "bad_request", message: "invalid date: #{params[:date]}",
      ))
    end

    # Spec §9.1: a date BEFORE today is outside this verb's domain and is
    # refused by name, because `200 []` for it is indistinguishable from the
    # honest empty case immediately below.
    refusal = WireArguments.past_date(date)
    return render_refusal(refusal) if refusal

    # PAST-SLOT FILTER: for TODAY, drop any slot whose start has already passed
    # in the operator's locale; future dates keep all slots. An assistant should
    # not see an un-bookable 08:00–10:00 window at 11:00. `date` on each row is
    # what create_order books.
    render_slots(date, zone)
  end

  # ── my_orders — per-principal: the caller's OWN orders only. The caller
  # supplies no filter; the scope is provider-controlled and un-bypassable.
  #
  # THE RECONCILIATION SURFACE: this is the "per-user query"
  # protocol.md §11.6 sends an assistant to after a `pay` whose response it never
  # read, so what it publishes about money is normative. `payment_state` is a
  # TRI-state and not a boolean, because a boolean conflates "nothing was ever
  # charged" with "a charge is outstanding" — and the second is where a fresh
  # mandate chain charges a human twice.
  kind :query
  description "List this principal's orders with their delivery window, address and where their money " \
              "stands (scoped to the authenticated account). This is the query to re-read after a " \
              "payment whose response never arrived: an order whose charge is still outstanding says " \
              "so rather than reporting itself unpaid, so a lost response can be reconciled instead of " \
              "guessed at. An order that has not been paid can still be changed in place with " \
              "`create_order`; a PAID one moves only through `reschedule_delivery`."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # `slot_at` and `address` are the two nullable columns on `orders` and travel
  # as null rather than being dropped, so the row shape does not change with the
  # order's completeness.
  output_schema type: "array",
                description: "The principal's orders, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    order_id:      { type: "string", description: "Pass to reschedule_delivery (or to create_order, to replace an unpaid order) as `order_id`." },
                    status:        { type: "string", description: "The operator's order status — where the BASKET stands (created, paying, paid, rescheduled). Read payment_state for where the money stands." },
                    total_cents:   { type: "integer", description: "EUR cents." },
                    slot_at:       { type: %w[string null], description: "The booked delivery window's start instant, ISO 8601 with offset, or null." },
                    address:       { type: %w[string null], description: "The delivery address on the order, or null." },
                    payment_state: { type: "string", enum: %w[unpaid pending paid],
                                     description: "Where this order's money stands, anchored to the CAPTURE and not to the operator's settlement record. `paid` = the charge went through; there is nothing to retry. `pending` = a capture for this order has been started and its outcome is not known yet — it may already have taken the money, so do NOT sign a fresh mandate chain: wait and re-read. `unpaid` = no capture has ever been started, and this is the only answer that makes a fresh chain correct." },
                  },
                  required: %w[order_id status total_cents slot_at address payment_state],
                }
  def my_orders
    # The paid witness is {Order.paid_flag} over the CALLER's settlements — the
    # same containment the operator's back office reads over ALL of them, so the
    # two surfaces are one behaviour with two authorities rather than two copies
    # of one SQL string (see {Order.settling}).
    render json: Order.owned_by_current_principal
                      .order(created_at: :desc)
                      .pluck(:id, :status, :total_cents, :slot_at, :address,
                             Order.paid_flag(Settlement.of_current_principal))
                      .map { |id, status, total_cents, slot_at, address, paid|
                        { "order_id"      => id,
                          "status"        => status,
                          "total_cents"   => total_cents,
                          # `pluck` casts a timestamptz to a TimeWithZone, whose
                          # JSON rendering of a UTC instant is "…Z" where this
                          # field publishes "…+00:00". Same instant, and the
                          # `getlocal(0)` is what keeps the spelling.
                          "slot_at"       => slot_at&.utc&.getlocal(0),
                          "address"       => address,
                          "payment_state" => Order.payment_state(status, paid) }
                      }
  end

  # ── kyc_status — poll a request_kyc verification the caller opened.
  kind :query
  description "Poll a verification `request_kyc` opened, until the human has acted on it. Three " \
              "answers: still waiting; APPROVED, carrying the broker's signed attestation, which you " \
              "submit to `POST <endpoint>/agents/kyc` before placing the order again; and DECLINED, " \
              "which is TERMINAL — do not keep polling it, start a fresh verification if the human " \
              "wants another try. The attestation is a full compact JWS: a long, single-line, " \
              "dot-separated token, and you submit the ENTIRE value, never a truncated console echo. " \
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
  # A ONE-ROW array: this is a query, and a query answers with rows. The two
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
    # sees the status — and the jws — of a request IT opened, and cannot lift the
    # attestation out of another agent's verification. `pick`, not `find_by!`:
    # the bang form raises RecordNotFound and the mixin's `rescue_from` floor
    # would render Rails' message instead of the operator's.
    row = KycVerificationRequest.owned_by_current_principal
                                .where(request_token: params[:request_id].to_s)
                                .pick(:status, :kyc_jws)
    if row.nil?
      return render_refusal(OperationResult.refused(
        code: "not_found", message: "no such verification request for this principal",
      ))
    end

    status, kyc_jws = row
    render json: (status == KycVerificationRequest::APPROVED ?
                    [{ "status" => status, "kyc_jws" => kyc_jws }] :
                    [{ "status" => status }])
  end

  private

  # One place that renders a slot row, because the date-supplied and
  # date-omitted paths must answer in exactly the same shape -- a caller that
  # omits the date is not getting a lesser response, it is getting the same one
  # for the day the operator picked. `date` on each row is what create_order
  # books, so it is the omitting caller's way of learning which day it got.
  def render_slots(date, zone)
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

  # `delivery_slots` says "missing PARAM" where every other verb on this origin
  # says "missing field": published behaviour, not an inconsistency to tidy away.
  def missing_param(field)
    OperationResult.refused(code: "bad_request", message: "missing param: #{field}")
  end
end
