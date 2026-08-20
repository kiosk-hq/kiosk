# frozen_string_literal: true

# book_table — hold ONE physical table at one restaurant for one upcoming
# seating, for the authenticated principal.
#
# THE GUARDS, IN THIS ORDER, and the order is behaviour rather than tidiness —
# each one is the answer a caller gets when a later one would also have refused,
# and the sequence below is the one the raw handler published, argument by
# argument:
#   1. every required argument is present and usable
#   2. the date parses, the time is one of the three seatings, and the seating
#      has not already started (re-validated against app/models/seatings.rb, so an agent
#      cannot book a window `availability` would now hide)
#   3. the chosen table exists at the chosen restaurant and seats the party
#   4. the (table, seating) is not already held — guarded TWICE, see below
#
# No payment: a reservation takes no money (the `deposit_eur` an availability row
# carries is a display-only no-show hold settled at the restaurant), so nothing
# here can mean a 402.
class BookTableOperation
  # @param principal_id [String] the account the wire resolved. NEVER an
  #   argument off the request.
  #
  #   An INSERT is the one place the principal must be spelled in Ruby, and K-654
  #   is where the asymmetry got named rather than papered over: `my_bookings` and
  #   `cancel_booking` scope with `Booking.owned_by_current_principal`, which
  #   never names the principal because a WHERE has a predicate to hide it in. An
  #   INSERT has no predicate, so it must supply the value. Both are un-forgeable
  #   for the same reason — the identity is resolved from the Rack env the wire
  #   built, which no request argument can write, and the GUC is set by SET LOCAL
  #   from that same resolved identity — but only the first keeps the DB as the
  #   authority. Moving the column's DEFAULT to `kiosk.current_user_id()` would
  #   close the gap; that is a migration, not part of a handler conversion.
  def self.call(principal_id:, restaurant_id:, restaurant_table_id:, date:, time:, party_size:)
    restaurant_id       = restaurant_id.to_i
    restaurant_table_id = restaurant_table_id.to_i
    date                = date.to_s
    time                = time.to_s
    return missing("restaurant_id")       if restaurant_id < 1
    return missing("restaurant_table_id") if restaurant_table_id < 1
    return missing("date")                if date.empty?
    return missing("time")                if time.empty?

    # The one guard `availability` shares, so the two surfaces cannot come to
    # disagree about what a bookable party is (see {WireArguments.party_size}).
    party_size, refusal = WireArguments.party_size(party_size)
    return refusal if refusal

    # The seating instant, from the SAME helper availability used. Reject a seating
    # that is not one of the current upcoming ones (past / wrong time), so an agent
    # can't book a window availability would now hide.
    parsed_date =
      begin
        Date.iso8601(date)
      rescue ArgumentError
        return bad_request("invalid date: #{date} — use the YYYY-MM-DD from an availability row")
      end
    unless Seatings::TIMES.include?(time)
      return bad_request("unknown seating time: #{time} — use \"19:00\" | \"20:00\" | \"21:00\"")
    end
    if Seatings.past?(parsed_date, time)
      return bad_request(
        "seating #{date} #{time} has already started — call availability again for the still-bookable seatings",
      )
    end
    seating_at = Seatings.seating_at(parsed_date, time)

    # This `transaction` JOINS the one Kiosk::Server::SessionContext already
    # opened around the whole wire request (the GUCs are SET LOCAL in it), so it
    # opens no second transaction and a `return` out of it is an ordinary method
    # return, not a non-local exit from a real transaction block.
    Booking.transaction do
      # The chosen table must exist at the chosen restaurant and seat the party.
      unless RestaurantTable.where(id: restaurant_table_id, restaurant_id: restaurant_id)
                            .where(RestaurantTable.arel_table[:capacity].gteq(party_size))
                            .exists?
        return bad_request(
          "no such table #{restaurant_table_id} at restaurant #{restaurant_id} seating #{party_size}",
        )
      end

      # ── The double-booking 409, guarded TWICE ────────────────────────────
      # First half: is this exact (table, seating) already held? A committed
      # conflict is answered here, before anything is written.
      if Booking.confirmed.where(restaurant_table_id: restaurant_table_id, seating_at: seating_at).exists?
        return already_booked(restaurant_table_id, date, time)
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
            { user_id:             principal_id,
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
          return already_booked(restaurant_table_id, date, time)
        end

      OperationResult.ok({
        booking_id:          booking["id"],
        restaurant_id:       restaurant_id,
        restaurant_table_id: restaurant_table_id,
        party_size:          booking["party_size"].to_i,
        date:                date,
        time:                time,
        seating_at:          seating_at.iso8601,
        status:              booking["status"],
      })
    end
  end

  # The sentence this verb raised for an argument it was not given, unchanged —
  # "param" and not "field", which is the wording book_table has always used and
  # is not this conversion's to normalise (`cancel_booking` next door says
  # "field"; both are published).
  def self.missing(param)
    bad_request("missing param: #{param}")
  end
  private_class_method :missing

  def self.bad_request(message)
    OperationResult.refused(code: "bad_request", message: message)
  end
  private_class_method :bad_request

  # Both halves of the double-booking guard — the pre-check and the unique
  # partial index that is authoritative under concurrency — answer with the SAME
  # sentence, so an assistant cannot tell (and need not care) which one caught it.
  def self.already_booked(restaurant_table_id, date, time)
    OperationResult.refused(
      code:    "conflict",
      message: "table #{restaurant_table_id} is already booked for #{date} #{time}",
    )
  end
  private_class_method :already_booked
end
