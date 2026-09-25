# frozen_string_literal: true

# atablefor's WRITE surface: the two verbs an assistant reaches with
# `POST /kiosk/<action-name>` — one endpoint per verb, arguments as
# the JSON body. Same shape as Kiosk::DiningRoomController — this app's own
# ApplicationController plus `include Kiosk::Handler` — and `kind :action` above
# each declaration is what puts it on `POST`. Each write reads its arguments,
# hands them to an Operation and renders what it answers.
#
# The wire's error-`code` vocabulary is a closed table, not a class hierarchy,
# so a refusal is an ordinary `render json:, status:` naming the code, which the
# wire carries verbatim into the RFC 9457 document's top-level `code`.
# {KioskRefusals#render_operation} is the one place a refusal becomes a status.
#
# No `pay` verb and no payment provider here: a `deposit_eur` is a display-only
# no-show hold settled at the restaurant, so nothing below is a 402 — the one an
# assistant can meet on this origin comes from the PoW gate upstream of dispatch.
class Kiosk::BookingsController < ApplicationController
  include Kiosk::Handler
  include KioskRefusals

  # book_table — reserve a specific table at a chosen restaurant for a chosen
  # upcoming seating, for the authenticated principal. The (restaurant_id,
  # restaurant_table_id) come from an availability row; the (date, time) seating
  # is re-validated through the same app/models/seatings.rb helper `availability`
  # filters with, so it must be one of the CURRENT upcoming seatings.
  # Contention is finite: a UNIQUE index on (restaurant_table_id, seating_at)
  # among confirmed rows makes a table already held a clean 409 Conflict. No
  # payment — any deposit shown is settled at the restaurant.
  # The description says WHAT booking means and WHEN it is refused; it
  # names no argument — `input_schema` below declares all five.
  kind :action
  description "Book a specific restaurant table for a chosen upcoming " \
              "seating, for the authenticated principal. Confirms the " \
              "reservation outright: there is no hold to release and nothing " \
              "is charged here — any deposit an availability row shows is " \
              "settled at the restaurant. Contention is real and finite, so a " \
              "table already held for that seating is refused as a clean " \
              "conflict rather than double-booked, and so is a seating that " \
              "has already passed. Every value it needs is on the " \
              "availability row the human picked."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 restaurant_id:       { type: "integer", minimum: 1,
                                        description: "The restaurant_id from an availability row." },
                 restaurant_table_id: { type: "integer", minimum: 1,
                                        description: "The restaurant_table_id from an availability row." },
                 date:                { type: "string", format: "date",
                                        description: "The seating_date (YYYY-MM-DD) from the availability row." },
                 time:                { type: "string", pattern: "^[0-2][0-9]:[0-5][0-9]$",
                                        description: "The seating_time HH:MM (24-hour), e.g. \"20:00\"." },
                 # THE CEILING IS DECLARED, not merely enforced — a
                 # refusal the published schema does not predict is its own
                 # defect. It is the width of `bookings.party_size` (and of the
                 # `restaurant_tables.capacity` this is compared against), so it
                 # is the column's own bound and not an invented house limit.
                 party_size:          { type: "integer", minimum: 1,
                                        maximum: WireArguments::MAX_INT4,
                                        description: "Number of guests." },
               },
               required: ["restaurant_id", "restaurant_table_id", "date", "time", "party_size"]
  # An action answers its own object. The five arguments come back echoed
  # because a confirmation an assistant reads back to its human has to name WHAT
  # was booked; `seating_at` is the absolute instant behind the (date, time).
  #
  # The confirmation carries `seating_label` for the same reason the availability
  # row does. `date` and `time` here ECHO the caller's own arguments, which is
  # exactly where the two sides may DISAGREE about which clock those words were
  # in — a zoneless "20:00" is the restaurant's, per the guard above, whatever
  # the assistant meant by it — and a booking confirmation is the artefact a
  # human keeps. So the same zone-bearing rendering `availability` and
  # `my_bookings` publish is on this row too, from the same {Seatings.label}:
  # one label, one spelling, every surface that writes a seating out — and
  # `timezone` names the clock,
  # which is the RESTAURANT's rather than this aggregator's.
  output_schema type: "object",
                description: "The confirmed booking.",
                additionalProperties: false,
                properties: {
                  booking_id:          { type: "string", description: "Pass to cancel_booking as `booking_id`." },
                  restaurant_id:       { type: "integer", description: "The restaurant booked." },
                  restaurant_table_id: { type: "integer", description: "The table held." },
                  party_size:          { type: "integer", description: "Guests the booking holds the table for." },
                  date:                { type: "string", description: "The seating date, YYYY-MM-DD, on the restaurant's own clock — the row publishes it as `timezone`." },
                  time:                { type: "string", description: "The seating time, HH:MM (24-hour) on THE RESTAURANT's own clock, " \
                                                                      "published as `timezone` — the table is there, so that is the " \
                                                                      "clock. `seating_at` is the same instant with its resolved " \
                                                                      "offset; `seating_label` is this time with the zone written " \
                                                                      "beside it." },
                  seating_label:       { type: "string", description: "The seating rendered for a human, IN THE ZONE IT NAMES — " \
                                                                      "e.g. \"20:00 (#{Seatings::DEFAULT_ZONE_NAME})\". This is the line " \
                                                                      "to read back to the human: `time` alone is a bare wall clock." },
                  seating_at:          { type: "string", description: "The seating instant, ISO 8601 carrying THIS RESTAURANT's offset — every verb of this demo publishes this field on the clock of the restaurant the row is about." },
                  timezone:            { type: "string", description: "The IANA zone this row is rendered in — a property of the RESTAURANT, not of this aggregator." },
                  status:              { type: "string", description: "confirmed." },
                },
                required: %w[booking_id restaurant_id restaurant_table_id party_size
                             date time seating_label seating_at timezone status]
  # THE SEATING IS RESOLVED, NOT WRITTEN DOWN. A calendar literal here
  # ages into a 400 the day that seating passes, so `example_params` and
  # `example_row` are RESOLVABLE slots ({Kiosk::Server::SchemaSlots}) naming the
  # same {Seatings} helpers `availability` uses — the three cannot drift.
  example_params({
    restaurant_id: 1, restaurant_table_id: 1,
    date: -> { Seatings.example_date.iso8601 }, time: Seatings::TIMES[1], party_size: 2,
  })
  example_row({
    booking_id: "b1f2a3c4-5d6e-4f70-8a91-2b3c4d5e6f70",
    restaurant_id: 1, restaurant_table_id: 1, party_size: 2,
    date: -> { Seatings.example_date.iso8601 }, time: Seatings::TIMES[1],
    seating_label: "#{Seatings::TIMES[1]} (#{Seatings::DEFAULT_ZONE_NAME})",
    seating_at: -> { Booking.publish_instant(Seatings.seating_at(Seatings.example_date, Seatings.example_time)) },
    timezone: Seatings::DEFAULT_ZONE_NAME,
    status: "confirmed",
  })
  def book_table
    render_operation BookTableOperation.call(
      principal_id:        kiosk_identity.user_id,
      restaurant_id:       params[:restaurant_id],
      restaurant_table_id: params[:restaurant_table_id],
      date:                params[:date],
      time:                params[:time],
      party_size:          params[:party_size],
    )
  end

  # cancel_booking — cancel one of the authenticated principal's own bookings,
  # freeing the (table, seating) so it can be booked again. Owner-scoped: the
  # WHERE gates on `user_id = kiosk.current_user_id()`, so a cross-principal
  # cancel is a clean 403 — the booking is not found under the caller's identity.
  kind :action
  description "Cancel one of the authenticated principal's own table bookings " \
              "(requires the booking to belong to the principal). Frees the (table, seating)."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 booking_id: { type: "string", format: "uuid",
                               description: "The booking to cancel — a `booking_id` from " \
                                            "book_table or my_bookings, verbatim; it must " \
                                            "belong to the principal." },
               },
               required: ["booking_id"]
  output_schema type: "object",
                description: "The cancelled booking.",
                additionalProperties: false,
                properties: {
                  booking_id: { type: "string", description: "The booking that was cancelled, echoed." },
                  status:     { type: "string", description: "cancelled." },
                },
                required: %w[booking_id status]
  def cancel_booking
    render_operation CancelBookingOperation.call(booking_id: params[:booking_id])
  end
end
