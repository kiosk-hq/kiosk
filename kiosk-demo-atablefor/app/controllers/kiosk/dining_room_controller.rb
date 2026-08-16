# frozen_string_literal: true

# atablefor's READ surface: the two verbs an assistant reaches with
# `POST /kiosk/query`. Kiosk ships a MIXIN, not a base class — the superclass is
# this app's own ApplicationController, and `include Kiosk::Query` is the whole
# contract. Each class-level macro records a declaration and the NEXT `def`
# claims it, so a method with no macros above it is a helper the wire cannot see.
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the write half lives next door in
# Kiosk::BookingsController. The one piece of domain logic BOTH halves need, the
# rolling upcoming seatings, was already a library module (lib/seatings.rb) and
# never controller code: `availability` offers a seating and `book_table`
# re-validates against the SAME helper, so the day+time an assistant is shown is
# exactly the one it can book. The only thing written twice is the four-line
# `render_bad_request` refusal below, which each controller keeps private —
# atablefor is the first demo whose READ half refuses at all.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the anti-scalping
# PoW toll and the GUC-scoped transaction live. A route drawn straight here would
# bypass all three, and the mixin answers such a request 404.
class Kiosk::DiningRoomController < ApplicationController
  include Kiosk::Query

  # availability — open tables ACROSS the restaurant aggregator for the upcoming
  # rolling seatings that seat the party. Public (no per-user scoping): any
  # authenticated agent may browse. The upcoming seatings (tonight's 19/20/21 in
  # Europe/Lisbon, past ones filtered, rolling to tomorrow) are computed by
  # lib/seatings.rb — so availability is NEVER stale. Tables are FINITE: a table
  # is "open" for a seating only when no CONFIRMED booking already holds it for
  # that exact (table, seating_at); when every table for a seating is taken,
  # availability is legitimately EMPTY for it (honest sell-out).
  #
  # Optional filters (all agent input goes through conn.quote — data, never SQL):
  #   :party_size   — only tables seating at least this many (used to size the party)
  #   :neighborhood — restrict to one Lisbon neighbourhood (e.g. "Alfama")
  #   :time         — restrict to one seating time ("19:00" | "20:00" | "21:00")
  #   :date         — restrict to one date (YYYY-MM-DD) among the upcoming seatings
  # The result is small (~5 restaurants × a handful of tables × ≤ a few seatings),
  # so it is NOT paginated.
  description "List open restaurant tables across the aggregator for the " \
              "UPCOMING seatings that seat the party (params: party_size; " \
              "optional neighborhood, time, date filters). Returns one row " \
              "per open (restaurant, table, seating): restaurant, " \
              "neighborhood, cuisine, restaurant_id, restaurant_table_id, " \
              "table_label, capacity, seating_date, seating_time, seating_at, " \
              "deposit_eur. Pass restaurant_id + restaurant_table_id + date + " \
              "time + party_size to book_table (all five are required) — the " \
              "row field named seating_date is book_table's `date` param, and " \
              "the row's seating_time is book_table's `time`: same values, " \
              "different names. Seatings are the current " \
              "upcoming ones (Europe/Lisbon), never stale; a seating with " \
              "every table taken is absent (sold out). deposit_eur is the " \
              "no-show hold in whole EUR (0 = none), settled at the " \
              "restaurant — no online payment. Small; not paginated."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 party_size:   { type: "integer", minimum: 1,
                                 description: "Number of guests." },
                 neighborhood: { type: "string",
                                 description: "Optional Lisbon neighbourhood filter, e.g. \"Alfama\"." },
                 time:         { type: "string", pattern: "^[0-2][0-9]:[0-5][0-9]$",
                                 description: "Optional seating-time filter, \"19:00\" | \"20:00\" | \"21:00\"." },
                 date:         { type: "string", format: "date",
                                 description: "Optional date filter, YYYY-MM-DD (must be among the upcoming seatings)." },
               },
               required: ["party_size"]
  example_params({ party_size: 2, neighborhood: "Alfama" })
  example_row({
    restaurant: "Tasca do Tejo", neighborhood: "Alfama",
    cuisine: "Portuguese tavern", restaurant_id: 1,
    restaurant_table_id: 1, table_label: "Window 6", capacity: 2,
    seating_date: "2026-08-08", seating_time: "20:00",
    seating_at: "2026-08-08T20:00:00+01:00", deposit_eur: 10,
  })
  def availability
    # An ABSENT party_size and a party_size that is present but unusable are two
    # different mistakes and keep their two different messages: the key check is
    # what the retired `params.fetch(:party_size) { raise }` did, and a present
    # nil still falls through to the >= 1 refusal below exactly as it did.
    return render_bad_request("missing param: party_size") unless params.key?(:party_size)

    party_size = params[:party_size].to_i
    return render_bad_request("party_size must be >= 1") if party_size < 1

    nbhd_filter = params[:neighborhood].to_s
    time_filter = params[:time].to_s
    date_filter = params[:date].to_s

    conn = ActiveRecord::Base.connection

    # The rolling upcoming seatings (Europe/Lisbon, past filtered, tonight→tomorrow),
    # each optionally narrowed by the agent's time/date filter.
    seatings = Seatings.upcoming
    seatings = seatings.select { |_d, t|   t == time_filter } unless time_filter.empty?
    seatings = seatings.select { |d, _t| d.iso8601 == date_filter } unless date_filter.empty?
    # `return`, and this time it is the RIGHT keyword (K-691). This used to be a
    # block the registry STORED and the Executor `.call`ed long after the
    # initializer's frame was gone, so a top-level `return` raised LocalJumpError
    # — rescued into ActionFailed, i.e. HTTP 500 — and `next []` was the fix. A
    # controller action is an ordinary method, so `return` returns from it: the
    # hazard is gone with the block, and the guard is written the plain way.
    #
    # It stays reachable with input the descriptor's own input_schema ACCEPTS:
    # `time: "18:00"` matches the declared pattern but is not one of
    # Seatings::TIMES, and any `date` outside the rolling horizon is a valid
    # `format: "date"`. Both empty the list here. Nothing validates the schema
    # server-side, so both reach the handler.
    #
    # An empty list is the right answer for both: the filters name a seating that
    # does not exist right now, which is the same thing as sold out from the
    # assistant's side — and `book_table` still rejects either with a typed 400
    # if the assistant tries to book one anyway.
    return render(json: []) if seatings.empty?

    # Every physical table seating >= party, optionally in one neighbourhood.
    where_nbhd = nbhd_filter.empty? ? "" : "AND r.neighborhood = #{conn.quote(nbhd_filter)} "
    tables = conn.execute(
      "SELECT rt.id AS restaurant_table_id, rt.label AS table_label, rt.capacity, rt.deposit_eur, " \
      "r.id AS restaurant_id, r.name AS restaurant, r.neighborhood, r.cuisine " \
      "FROM restaurant_tables rt " \
      "JOIN restaurants r ON r.id = rt.restaurant_id " \
      "WHERE rt.capacity >= #{party_size} #{where_nbhd}" \
      "ORDER BY r.name, rt.capacity, rt.label",
    ).to_a

    # Confirmed holds on any of the upcoming seatings — used to subtract taken
    # (table, seating) pairs so availability sells out honestly. Keyed on the
    # ABSOLUTE instant (UTC epoch seconds) so the match is timezone-agnostic — the
    # seating_at column is timestamptz, and Seatings.seating_at is a zoned Lisbon
    # Time; both reduce to the same epoch, sidestepping session-TZ formatting.
    seating_epochs = seatings.map { |d, t| Seatings.seating_at(d, t).to_i }
    taken = {}
    unless seating_epochs.empty?
      in_list = seatings.map { |d, t| "#{conn.quote(Seatings.seating_at(d, t).iso8601)}::timestamptz" }.join(", ")
      conn.execute(
        "SELECT restaurant_table_id, EXTRACT(EPOCH FROM seating_at)::bigint AS epoch " \
        "FROM bookings WHERE status = 'confirmed' AND seating_at IN (#{in_list})",
      ).each { |row| taken["#{row["restaurant_table_id"]}@#{row["epoch"]}"] = true }
    end

    rows = []
    seatings.each do |date, time|
      seating_at = Seatings.seating_at(date, time)
      key_epoch  = seating_at.to_i
      tables.each do |t|
        next if taken["#{t["restaurant_table_id"]}@#{key_epoch}"]

        rows << {
          "restaurant"          => t["restaurant"],
          "neighborhood"        => t["neighborhood"],
          "cuisine"             => t["cuisine"],
          "restaurant_id"       => t["restaurant_id"],
          "restaurant_table_id" => t["restaurant_table_id"],
          "table_label"         => t["table_label"],
          "capacity"            => t["capacity"],
          "seating_date"        => date.iso8601,
          "seating_time"        => time,
          "seating_at"          => seating_at.iso8601,
          "deposit_eur"         => t["deposit_eur"],
        }
      end
    end

    render json: rows
  end

  # my_bookings — per-user booking list scoped by the session GUC.
  # The WHERE is provider-controlled; the agent supplies no filter. This
  # demonstrates app-layer per-user isolation: the principal can only see rows
  # where user_id matches kiosk.current_user_id(), enforced in the query itself.
  description "List this principal's table bookings across all restaurants " \
              "(scoped to the authenticated user via kiosk.current_user_id()). " \
              "Each row carries a `booking_id`; pass it to cancel_booking as " \
              "`booking_id`."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  def my_bookings
    render json: ActiveRecord::Base.connection.execute(
      "SELECT b.id AS booking_id, b.restaurant_id, r.name AS restaurant, r.neighborhood, " \
      "b.restaurant_table_id, rt.label AS table_label, b.party_size, b.status, " \
      "to_char(b.seating_at AT TIME ZONE 'Europe/Lisbon', 'YYYY-MM-DD') AS seating_date, " \
      "to_char(b.seating_at AT TIME ZONE 'Europe/Lisbon', 'HH24:MI')    AS seating_time, " \
      "b.seating_at " \
      "FROM bookings b " \
      "JOIN restaurant_tables rt ON rt.id = b.restaurant_table_id " \
      "JOIN restaurants r        ON r.id  = b.restaurant_id " \
      "WHERE b.user_id = kiosk.current_user_id() " \
      "ORDER BY b.seating_at",
    ).to_a
  end

  private

  # The whole error surface of this controller is one refusal, and it is a plain
  # `render json:, status:` naming a code from the wire's closed vocabulary.
  # Naming it is what lets an assistant branch; the status alone would already
  # imply this one, but writing it keeps the answer explicit.
  def render_bad_request(message)
    render json: { error: { code: "bad_request", message: message } },
           status: :bad_request
  end
end
