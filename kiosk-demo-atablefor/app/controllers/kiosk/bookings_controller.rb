# frozen_string_literal: true

# atablefor's WRITE surface: the two verbs an assistant reaches with
# `POST /kiosk/run`. Same shape as Kiosk::DiningRoomController — this app's own
# ApplicationController plus `include Kiosk::Action` — because a controller
# declares queries OR actions, never both.
#
# Errors are Rails' idiom end to end: the wire's `error.code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code, and the wire carries it verbatim. No
# Kiosk error classes appear below — the sixteen `Errors::BadRequest` /
# `Errors::Conflict` / `Errors::Forbidden` raises this file replaces are now
# three private renderers.
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
    restaurant_id       = params[:restaurant_id].to_i
    restaurant_table_id = params[:restaurant_table_id].to_i
    date                = params[:date].to_s
    time                = params[:time].to_s
    party_size          = params[:party_size].to_i
    return render_bad_request("missing param: restaurant_id")       if restaurant_id < 1
    return render_bad_request("missing param: restaurant_table_id") if restaurant_table_id < 1
    return render_bad_request("missing param: date")                if date.empty?
    return render_bad_request("missing param: time")                if time.empty?
    return render_bad_request("party_size must be >= 1")             if party_size < 1

    # The seating instant, from the SAME helper availability used. Reject a seating
    # that is not one of the current upcoming ones (past / wrong time), so an agent
    # can't book a window availability would now hide.
    parsed_date =
      begin
        Date.iso8601(date)
      rescue ArgumentError
        return render_bad_request("invalid date: #{date} — use the YYYY-MM-DD from an availability row")
      end
    return render_bad_request("unknown seating time: #{time} — use \"19:00\" | \"20:00\" | \"21:00\"") unless Seatings::TIMES.include?(time)
    if Seatings.past?(parsed_date, time)
      return render_bad_request(
        "seating #{date} #{time} has already started — call availability again for the still-bookable seatings",
      )
    end
    seating_at = Seatings.seating_at(parsed_date, time)

    # The principal, from the identity the WIRE resolved — never from an
    # argument. This used to be `SELECT kiosk.current_user_id()`, and K-654 is
    # where the asymmetry got named rather than papered over: my_bookings and
    # cancel_booking scope with `Booking.owned_by_current_principal`, which never
    # spells the principal in Ruby because a WHERE has a predicate to hide it in.
    # An INSERT has no predicate, so it must supply the value. Both are
    # un-forgeable for the same reason — `kiosk_identity` is read from the Rack
    # env the wire built, which no request argument can write, and the GUC is set
    # by SET LOCAL from that same resolved identity — but only the first keeps
    # the DB as the authority. Moving the column's DEFAULT to
    # `kiosk.current_user_id()` would close the gap; that is a migration, so it
    # is not part of the handler conversion.
    uid = kiosk_identity.user_id

    # This `transaction` JOINS the one Kiosk::Server::SessionContext already
    # opened around the whole wire request (the GUCs are SET LOCAL in it), so it
    # opens no second transaction and a `return` out of it is an ordinary method
    # return, not a non-local exit from a real transaction block.
    Booking.transaction do
      # The chosen table must exist at the chosen restaurant and seat the party.
      unless RestaurantTable.where(id: restaurant_table_id, restaurant_id: restaurant_id)
                            .where(RestaurantTable.arel_table[:capacity].gteq(party_size))
                            .exists?
        return render_bad_request(
          "no such table #{restaurant_table_id} at restaurant #{restaurant_id} seating #{party_size}",
        )
      end

      # ── The double-booking 409, guarded TWICE ────────────────────────────
      # First half: is this exact (table, seating) already held? A committed
      # conflict is answered here, before anything is written.
      if Booking.confirmed.where(restaurant_table_id: restaurant_table_id, seating_at: seating_at).exists?
        return render_already_booked(restaurant_table_id, date, time)
      end

      booking =
        begin
          # Second half, and the authoritative one: the UNIQUE PARTIAL INDEX. The
          # pre-check above runs at READ COMMITTED, so it cannot see a competing
          # booking that has not committed yet — under real concurrency the index
          # is the only thing that can say no.
          #
          # `insert!` and NOT `create!`, deliberately. The rescue below depends on
          # WHICH exception class arrives, and that is exactly what changes when a
          # raw INSERT becomes a model write: `create!` interposes validations, so
          # `belongs_to :user` would turn a principal with no `users` row from the
          # `ActiveRecord::InvalidForeignKey` Postgres raises into a
          # `RecordInvalid` — a different answer on the wire for an unrelated
          # input. `insert!` is the faithful translation: one INSERT … RETURNING,
          # the database constraints as the sole authority, `RecordNotUnique`
          # still raised by the index, timestamps still written.
          Booking.insert!(
            { user_id:             uid,
              restaurant_id:       restaurant_id,
              restaurant_table_id: restaurant_table_id,
              party_size:          party_size,
              seating_at:          seating_at,
              status:              Booking::CONFIRMED },
            returning: %i[id party_size status],
          ).first
        rescue ActiveRecord::RecordNotUnique
          # Lost a race for the same (table, seating) — the unique index caught
          # it. The SAME sentence as the pre-check, so an assistant cannot tell
          # (and need not care) which half refused.
          return render_already_booked(restaurant_table_id, date, time)
        end

      render json: {
        booking_id:          booking["id"],
        restaurant_id:       restaurant_id,
        restaurant_table_id: restaurant_table_id,
        party_size:          booking["party_size"].to_i,
        date:                date,
        time:                time,
        seating_at:          seating_at.iso8601,
        status:              booking["status"],
      }
    end
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
    booking_id = params[:booking_id]
    return render_bad_request("missing field: booking_id") if booking_id.blank?

    # K-581/K-582, and the guard got MORE load-bearing once the SQL became
    # ActiveRecord (K-654). It was written because this id was cast `::uuid`, and
    # a malformed one made Postgres raise InvalidTextRepresentation — not a Kiosk
    # error, so it escaped as a raw 500 leaking "invalid input syntax for type
    # uuid". `where(id:)` does not raise on junk: ActiveRecord's uuid type quietly
    # casts an unparseable value to NULL, which matches no row and would answer
    # 403 — a client's typo reported as an ownership refusal. Check the shape
    # first, answer 400; a well-formed but foreign id still gets the 403, so the
    # shape check never softens the ownership answer.
    unless UuidCheck.valid?(booking_id)
      return render_bad_request(
        "booking_id #{booking_id.to_s.inspect} is not a uuid — pass the `booking_id` " \
        "that book_table returned (also listed by my_bookings)",
      )
    end

    # Owner-scoped, in ONE statement. It was two — a SELECT that decided the 403
    # and an UPDATE that did the work — and collapsing them is not just tidier:
    # the ownership test and the write can no longer be separated by another
    # transaction. `update_all` (not `update!`) keeps that single-statement
    # property and skips validations exactly as the previous UPDATE did; the row
    # count IS the answer. Cancelling drops the row out of the confirmed set, so
    # the unique partial index frees the (table, seating) for a fresh booking.
    cancelled = Booking.owned_by_current_principal
                       .where(id: booking_id)
                       .where.not(status: Booking::CANCELLED)
                       .update_all(status: Booking::CANCELLED, updated_at: Time.current)

    return render_not_owner if cancelled.zero?

    render json: { booking_id: booking_id, status: "cancelled" }
  end

  private

  # The three refusals below are the whole error surface of this controller, and
  # each is a plain `render json:, status:` naming a code from the wire's closed
  # vocabulary. Naming it is what lets an assistant branch; the status alone
  # would already imply each of these, but writing it keeps the answer explicit.
  def render_bad_request(message)
    render json: { error: { code: "bad_request", message: message } },
           status: :bad_request
  end

  # Both halves of the double-booking guard — the pre-check and the unique
  # partial index that is authoritative under concurrency — answer with the SAME
  # sentence, so an assistant cannot tell (and need not care) which one caught it.
  def render_already_booked(restaurant_table_id, date, time)
    render json: { error: { code:    "conflict",
                            message: "table #{restaurant_table_id} is already booked for #{date} #{time}" } },
           status: :conflict
  end

  # Owner-scoped miss. Deliberately ONE answer for "no such booking", "not
  # yours" and "already cancelled": distinguishing them would let a caller
  # enumerate other principals' booking ids.
  def render_not_owner
    render json: { error: { code:    "forbidden",
                            message: "booking not found, not yours, or already cancelled" } },
           status: :forbidden
  end
end
