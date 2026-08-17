# frozen_string_literal: true

# atablefor's WRITE surface: the two verbs an assistant reaches with
# `POST /kiosk/run`. Same shape as Kiosk::DiningRoomController — this app's own
# ApplicationController plus `include Kiosk::Action` — because a controller
# declares queries OR actions, never both.
#
# THE TWO WRITES ARE A HANDFUL OF LINES EACH: read the arguments off the request,
# hand them to an Operation, render what it answers (T-083, Phil's 2026-08-17
# WRITE-OPERATIONS-SEAM decision). That is the fleet's shape, not this demo's
# invention — `book_table` ends in a transaction whose double-booking guard is in
# TWO halves, the second of them reached only from inside a `rescue` around an
# INSERT, and a `render` in the middle of that is what every T-057 slice had to
# reason about.
#
# Errors are Rails' idiom end to end: the wire's `error.code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code, and the wire carries it verbatim. No
# Kiosk error classes appear below — the sixteen `Errors::BadRequest` /
# `Errors::Conflict` / `Errors::Forbidden` raises this file once replaced are now
# {OperationResult} refusals, and {KioskRefusals#render_operation} is the one
# place a refusal becomes a status.
#
# atablefor advertises NO `pay` verb and configures no payment provider: the
# `deposit_eur` an availability row carries is a display-only no-show hold
# settled at the restaurant. So nothing here means a 402 — the wire's three
# payment/PoW codes share that status and `Errors::STATUS_CODES` deliberately
# refuses to guess between them, but no refusal below is a 402-class refusal, and
# the 402 an assistant does meet on this origin comes from the anti-scalping PoW
# gate upstream of dispatch, not from a handler.
#
# NOT ROUTABLE — see Kiosk::DiningRoomController.
class Kiosk::BookingsController < ApplicationController
  include Kiosk::Action
  include KioskRefusals

  # book_table — reserve a specific table at a chosen restaurant for a chosen
  # upcoming seating, for the authenticated principal. The (restaurant_id,
  # restaurant_table_id) come from an availability row; the seating is
  # (date, time). The seating must be one of the CURRENT upcoming seatings (not
  # past — re-validated against lib/seatings.rb). Contention is finite: a UNIQUE
  # index on (restaurant_table_id, seating_at) among confirmed rows means a table
  # already held for that seating is a clean 409 Conflict. No payment — a
  # reservation takes no money (any deposit shown is settled at the restaurant).
  description "Book a specific restaurant table for a chosen upcoming " \
              "seating (params: restaurant_id, restaurant_table_id, date, " \
              "time, party_size — all from an availability row). Confirms " \
              "the reservation; a table already taken for that seating, or a " \
              "seating that has passed, is rejected cleanly."
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
                 party_size:          { type: "integer", minimum: 1,
                                        description: "Number of guests." },
               },
               required: ["restaurant_id", "restaurant_table_id", "date", "time", "party_size"]
  example_params({
    restaurant_id: 1, restaurant_table_id: 1,
    date: "2026-08-08", time: "20:00", party_size: 2,
  })
  example_row({
    booking_id: "b1f2a3c4-5d6e-4f70-8a91-2b3c4d5e6f70",
    restaurant_id: 1, restaurant_table_id: 1, party_size: 2,
    date: "2026-08-08", time: "20:00",
    seating_at: "2026-08-08T20:00:00+01:00", status: "confirmed",
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
  # WHERE gates on user_id = kiosk.current_user_id(), so a cross-principal cancel
  # on another's booking is a clean 403 (the booking is not found under the
  # caller's identity).
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
  def cancel_booking
    render_operation CancelBookingOperation.call(booking_id: params[:booking_id])
  end
end
