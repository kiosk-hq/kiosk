# frozen_string_literal: true

# The read verbs.

class Kiosk::StorefrontController < ActionController::API
  include Kiosk::Handler

  kind :query
  description "Browse the getgrocery catalogue. Only what is IN STOCK appears — a sold-out product is " \
              "absent rather than listed as unavailable. A cart is signed at exactly the price the " \
              "shelf shows, so re-read it before paying rather than " \
              "trusting a price you cached. Two flags matter to an assistant: one marks a product " \
              "whose stock is running out, and one marks alcohol — which `create_order` accepts only " \
              "from an account that has already completed an 18+ anonymized-KYC check, and " \
              "`request_kyc` is what starts one. Nothing else on this shelf needs a check."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
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
    render json: Product.in_stock.order(:name).map { |product|
      row = { "sku"         => product.sku,
              "name"        => product.name,
              "price_cents" => product.price_cents,
              "price_eur"   => Product.format_eur(product.price_cents),
              "currency"    => "eur" }
      row["low"] = true if product.low_stock?
      row["age_restricted"] = true if product.age_restricted?
      row
    }
  end

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
                                     description: "Delivery date, YYYY-MM-DD, read in YOUR " \
                                                  "OWN calendar -- declare it in the `Kiosk-Timezone` " \
                                                  "request header and \"today\" means your human's " \
                                                  "today, not the shop's. Declare none and it is read " \
                                                  "at the delivery address. OMIT the field entirely " \
                                                  "for the soonest day this shop can deliver. A day " \
                                                  "that has entirely ENDED for you is refused with the " \
                                                  "earliest bookable one named; a day you are still in " \
                                                  "is answered even when the shop has already rolled " \
                                                  "over, and the row then carries the SHOP's date, " \
                                                  "which is how you learn that. Every row carries the " \
                                                  "date it is for and the zone it is written in." },
                 delivery_address: { type: "string", description: "Dublin delivery address naming a served postal district." },
               },
               required: ["delivery_address"]
  output_schema type: "array",
                description: "The still-bookable delivery windows for the requested date and district.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    delivery_slot_id: { type: "integer", description: "Pass to create_order as `delivery_slot_id`." },
                    date:             { type: "string", description: "YYYY-MM-DD — pass to create_order as `delivery_date` so the booking lands on the day you saw." },
                    slot_at:          { type: "string", description: "The window's start instant, ISO 8601 with offset." },
                    label:            { type: "string", description: "The window rendered for a human, IN THE ZONE IT NAMES — " \
                                                                    "e.g. \"08:00–10:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})\". The wall clock " \
                                                                    "is the delivery address's, not the caller's; `slot_at` carries " \
                                                                    "the same instant with its resolved offset." },
                    timezone:         { type: "string", description: "The IANA zone this row is rendered in — a property of the DELIVERY ADDRESS, not of this shop. `date` is a day on this calendar." },
                    district:         { type: "string", description: "The served Dublin postal district the address routed to (e.g. \"D02\") — a ROUTING key, not a time zone." },
                  },
                  required: %w[delivery_slot_id date slot_at label timezone district],
                }
  example_params({ date:             -> { DeliverySlots.example_date.iso8601 },
                   delivery_address: "42 Camden Street, Dublin 2" })
  example_row({ delivery_slot_id: 1,
                date:    -> { DeliverySlots.example_date.iso8601 },
                slot_at: -> { DeliverySlots.slot_at(DeliverySlots.example_date, 1).iso8601 },
                label: "08:00–10:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})",
                timezone: DeliverySlots::DEFAULT_ZONE_NAME, district: "D02" })
  def delivery_slots
    district = WireArguments.served_district(params[:delivery_address])
    zone     = DeliverySlots.zone_for(district)
    soonest  = DeliverySlots.soonest_date(zone)
    date     = params.key?(:date) ? requested_day(zone, soonest) : soonest

    render json: DeliverySlots.bookable_ids(date, zone).map { |slot_id|
      slot_at = DeliverySlots.slot_at(date, slot_id, zone)
      { "delivery_slot_id" => slot_id,
        "date"             => date.iso8601,
        "slot_at"          => slot_at.iso8601,
        "label"            => DeliverySlots.label(slot_at, zone),
        "timezone"         => zone.name,
        "district"         => district }
    }
  end

  kind :query
  description "List this principal's orders with their delivery window, address and where their money " \
              "stands (scoped to the authenticated account). This is the query to re-read after a " \
              "payment whose response never arrived: an order whose charge is still outstanding says " \
              "so rather than reporting itself unpaid, so a lost response can be reconciled instead of " \
              "guessed at. An order nobody has paid for is never delivered and never charged, so a " \
              "change of mind is a NEW `create_order`; a PAID one moves only through " \
              "`reschedule_delivery`."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The principal's orders, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    order_id:      { type: "string", description: "Pass to reschedule_delivery as `order_id` once this order is paid." },
                    status:        { type: "string", enum: Order.statuses.keys,
                                     description: "Where the BASKET stands: created → paying → paid, rescheduled once its window has been moved, then out_for_delivery and delivered as the shop's courier acts. Read payment_state for where the money stands." },
                    total_cents:   { type: "integer", description: "EUR cents." },
                    slot_at:       { type: "string", description: "The booked delivery window's start instant, ISO 8601 with offset. " \
                                                                        "The offset is the DELIVERY zone's — the same one `delivery_slots`, " \
                                                                        "`create_order` and `reschedule_delivery` gave you for this window, so " \
                                                                        "the four verbs spell one instant one way." },
                    slot_label:    { type: "string", description: "The booked window rendered for a human, IN THE ZONE IT NAMES — " \
                                                                        "e.g. \"08:00–10:00 (#{DeliverySlots::DEFAULT_ZONE_NAME})\". The wall clock is the delivery address's, not the caller's; " \
                                                                        "`slot_at` carries the same instant with its resolved offset." },
                    address:       { type: "string", description: "The delivery address on the order." },
                    payment_state: { type: "string", enum: %w[unpaid pending paid],
                                     description: "Where this order's money stands, anchored to the CAPTURE and not to the operator's settlement record. `paid` = the charge went through; there is nothing to retry. `pending` = a capture for this order has been started and its outcome is not known yet — it may already have taken the money, so do NOT sign a fresh mandate chain: wait and re-read. `unpaid` = no capture has ever been started, and this is the only answer that makes a fresh chain correct." },
                  },
                  required: %w[order_id status total_cents slot_at slot_label address payment_state],
                }
  def my_orders
    render json: Order.own.with_settlement(Kiosk::Settlement.own).order(created_at: :desc).map { |order|
      { "order_id"      => order.id,
        "status"        => order.status,
        "total_cents"   => order.total_cents,
        "slot_at"       => order.slot_at.in_time_zone(order.zone).iso8601,
        "slot_label"    => DeliverySlots.label(order.slot_at, order.zone),
        "address"       => order.address,
        "payment_state" => order.payment_state }
    }
  end

  private

  def requested_day(zone, soonest)
    date = WireArguments.calendar_day(params[:date]) ||
           WireArguments.refuse("invalid date: #{params[:date]} — use YYYY-MM-DD")
    WireArguments.caller_day(date, zone: zone, caller_zone: Kiosk::Server::CurrentRequest.timezone,
                                   soonest: soonest)
  end
end
