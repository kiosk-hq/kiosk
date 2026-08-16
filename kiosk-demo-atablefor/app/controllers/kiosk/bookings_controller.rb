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
    conn = ActiveRecord::Base.connection

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

    # Identity is set via Kiosk::Server::SessionContext SET LOCAL —
    # current_user_id() returns the principal. ActiveRecord doesn't have direct
    # access; pull from PG. (The mixin's `kiosk_identity` carries the same
    # principal, but the GUC is what my_bookings scopes on next door, so the write
    # side reads the same source rather than a second one that could drift.)
    uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]

    # This `transaction` JOINS the one Kiosk::Server::SessionContext already
    # opened around the whole wire request (the GUCs above are SET LOCAL in it),
    # so it opens no second transaction and a `return` out of it is an ordinary
    # method return, not a non-local exit from a real transaction block.
    conn.transaction do
      # The chosen table must exist at the chosen restaurant and seat the party.
      table = conn.execute(
        "SELECT rt.id, rt.capacity FROM restaurant_tables rt " \
        "WHERE rt.id = #{restaurant_table_id} AND rt.restaurant_id = #{restaurant_id} " \
        "AND rt.capacity >= #{party_size} " \
        "LIMIT 1",
      ).first
      if table.nil?
        return render_bad_request(
          "no such table #{restaurant_table_id} at restaurant #{restaurant_id} seating #{party_size}",
        )
      end

      # Finite contention: is this exact (table, seating) already held? A clean
      # 409 Conflict, mirrored by the unique partial index (the index is the
      # authoritative guard even under concurrency).
      held = conn.execute(
        "SELECT 1 FROM bookings WHERE status = 'confirmed' " \
        "AND restaurant_table_id = #{restaurant_table_id} " \
        "AND seating_at = #{conn.quote(seating_at.iso8601)}::timestamptz LIMIT 1",
      ).first
      return render_already_booked(restaurant_table_id, date, time) if held

      booking =
        begin
          conn.execute(
            "INSERT INTO bookings " \
            "(id, user_id, restaurant_id, restaurant_table_id, party_size, seating_at, status, created_at, updated_at) " \
            "VALUES (gen_random_uuid(), #{conn.quote(uid.to_s)}::uuid, #{restaurant_id}, #{restaurant_table_id}, " \
            "#{party_size}, #{conn.quote(seating_at.iso8601)}::timestamptz, 'confirmed', now(), now()) " \
            "RETURNING id, party_size, status",
          ).first
        rescue ActiveRecord::RecordNotUnique
          # Lost a race for the same (table, seating) — the unique index caught it.
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
    conn = ActiveRecord::Base.connection

    booking_id = params[:booking_id]
    return render_bad_request("missing field: booking_id") if booking_id.blank?

    # K-581/K-582: this id is cast `::uuid` below — a malformed one made Postgres
    # raise InvalidTextRepresentation, which is not a Kiosk error and so surfaced
    # as a raw 500 (leaking "invalid input syntax for type uuid") for what is
    # plainly a client mistake. Check the shape first, answer 400.
    unless UuidCheck.valid?(booking_id)
      return render_bad_request(
        "booking_id #{booking_id.to_s.inspect} is not a uuid — pass the `booking_id` " \
        "that book_table returned (also listed by my_bookings)",
      )
    end

    # Joins the wire request's SessionContext transaction — see book_table.
    conn.transaction do
      # Owner-scoped: the booking must belong to the caller and not be cancelled.
      booking = conn.execute(
        "SELECT id FROM bookings " \
        "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
        "AND user_id = kiosk.current_user_id() " \
        "AND status <> 'cancelled' " \
        "LIMIT 1",
      ).first
      return render_not_owner if booking.nil?

      # Cancelling drops the row out of the confirmed set, so the unique partial
      # index frees the (table, seating) for a fresh booking.
      conn.execute(
        "UPDATE bookings SET status = 'cancelled', updated_at = now() " \
        "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
        "AND user_id = kiosk.current_user_id()",
      )

      render json: { booking_id: booking_id, status: "cancelled" }
    end
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
