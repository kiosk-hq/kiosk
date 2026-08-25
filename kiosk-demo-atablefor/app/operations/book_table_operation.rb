# frozen_string_literal: true

# book_table — hold ONE physical table at one restaurant for one upcoming
# seating, for the authenticated principal. No payment: a reservation takes no
# money, so nothing here can mean a 402.
#
# THE GUARDS RUN IN THIS ORDER, and the order is behaviour: each one is the
# answer a caller gets when a later one would also have refused.
#   1. every required argument is present and usable
#   2. the date parses, the time is one of the three seatings, and the (date,
#      time) pair is one `availability` is CURRENTLY offering — re-validated
#      against app/models/seatings.rb, so an agent cannot book a window
#      `availability` would now hide
#   3. the chosen table exists at the chosen restaurant and seats the party
#   4. the (table, seating) is not already held — guarded TWICE, see below
class BookTableOperation
  # @param principal_id [String] the account the wire resolved. NEVER an
  #   argument off the request.
  #
  #   An INSERT is the one place the principal is spelled in Ruby (K-654): the
  #   owner-scoped reads hide it in a WHERE (`owned_by_current_principal`), an
  #   INSERT has no predicate to hide it in. Both are un-forgeable — the identity
  #   comes from the Rack env the wire built, which no request argument can write
  #   — but only the WHERE keeps the DB as the authority.
  def self.call(principal_id:, restaurant_id:, restaurant_table_id:, date:, time:, party_size:)
    restaurant_id, refusal = identifier("restaurant_id", restaurant_id)
    return refusal if refusal

    restaurant_table_id, refusal = identifier("restaurant_table_id", restaurant_table_id)
    return refusal if refusal

    date = date.to_s
    time = time.to_s
    return missing("date") if date.empty?
    return missing("time") if time.empty?

    # The one guard `availability` shares, so the two surfaces cannot disagree.
    party_size, refusal = WireArguments.party_size(party_size)
    return refusal if refusal

    # The seating instant, from the SAME helper availability used: a seating
    # that is past, at an hour nobody seats at, or beyond the horizon is refused.
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

    # NOT PAST IS NOT THE SAME AS OFFERED (K-767): `availability` publishes a
    # ROLLING horizon, so a well-formed future date outside it must be refused
    # too — by the SAME helper `availability` filters its own `date` with.
    _in_horizon, refusal = WireArguments.seating_date(date, Seatings.upcoming)
    return refusal if refusal

    seating_at = Seatings.seating_at(parsed_date, time)

    # This `transaction` JOINS the one Kiosk::Server::SessionContext already
    # opened around the whole wire request (the GUCs are SET LOCAL in it), so a
    # `return` out of it is an ordinary method return, not a non-local exit.
    Booking.transaction do
      unless RestaurantTable.where(id: restaurant_table_id, restaurant_id: restaurant_id)
                            .where(RestaurantTable.arel_table[:capacity].gteq(party_size))
                            .exists?
        return bad_request(
          "no such table #{restaurant_table_id} at restaurant #{restaurant_id} seating #{party_size}",
        )
      end

      # ── The double-booking 409, guarded TWICE ────────────────────────────
      # First half: a COMMITTED conflict, answered before anything is written.
      if Booking.confirmed.where(restaurant_table_id: restaurant_table_id, seating_at: seating_at).exists?
        return already_booked(restaurant_table_id, date, time)
      end

      booking =
        begin
          # Second half, and the authoritative one: the UNIQUE PARTIAL INDEX.
          # The pre-check runs at READ COMMITTED and cannot see an uncommitted
          # competitor, so under concurrency the index is the only thing that
          # can say no. `insert!` and NOT `create!`, deliberately: the rescue
          # below depends on WHICH exception arrives, and `create!` would
          # interpose validations — `belongs_to :user` would turn the
          # `ActiveRecord::InvalidForeignKey` Postgres raises into a
          # `RecordInvalid`, a different answer on the wire.
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
          # Lost the race — the unique index caught it. The SAME sentence as the
          # pre-check, so an assistant cannot tell which half refused.
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

  # "param", not "field": that is the wording book_table publishes
  # (`cancel_booking` next door says "field"; both are published as they are).
  def self.missing(param)
    bad_request("missing param: #{param}")
  end
  private_class_method :missing

  # A restaurant or table identifier: SHAPE first, then RANGE — the same two
  # steps in the same order {WireArguments.party_size} takes, and only since
  # K-1028 (the two arguments K-1027's fix text did not name, same defect, same
  # method, one line apart).
  #
  # THIS PAIR READ A BARE `.to_i`, and MEASURED on the descriptor-less path —
  # the only path where either argument is uncoerced, and the path
  # {WireArguments}' own comment names as its reason to exist — that got two
  # things wrong at once:
  #
  #   * `true`, `false`, `[]`, `{}`, `[1]` and `{"a" => 1}` have no `to_i` AT
  #     ALL, so each raised `NoMethodError` — a `500 action_failed` for a value
  #     `input_schema` already forbids;
  #   * `1.5.to_i` is 1, so a fractional id RESOLVED TO A ROW THE CALLER DID NOT
  #     NAME. Watched rather than argued: `BookTableOperation.call` with
  #     `restaurant_id: 1.5, restaurant_table_id: 1` returned a CONFIRMED
  #     BOOKING at restaurant 1 table 1, and `restaurant_table_id: 1.5` against
  #     restaurant 2 answered "no such table 1 at restaurant 2" — a refusal
  #     naming a table nobody asked for. Which of the two a caller met was the
  #     SEEDED DATA's choice, not the guard's.
  #
  # The shape is {WireArguments.whole_number}'s, so it is json_schemer's own
  # `integer` and nothing looser: `2.0` still resolves to 2, exactly as `.to_i`
  # did and exactly as the declared `{type: "integer"}` in front of it allows
  # (measured against this demo's bundle on K-1027). A bare `is_a?(Integer)`
  # here would refuse a body the published descriptor calls valid.
  #
  # THREE REFUSALS, ONE PER THING THAT CAN BE WRONG, and the split is behaviour
  # rather than decoration — an error body an assistant acts on has to say which
  # of the three it was:
  #
  #   * NOT GIVEN — `nil` is what the controller passes for an argument that was
  #     not given, and that keeps "missing param: …" byte-for-byte;
  #   * GIVEN, WRONG SHAPE — the values that used to be a 500 or a wrong row;
  #   * GIVEN, OUT OF RANGE — a `0` or a negative id, which parsed fine and the
  #     guard has already read.
  #
  # THE THIRD ONE ANSWERED "missing param: …" UNTIL K-1030 — a sentence that told
  # the caller the argument had not been given when it had been, which is the
  # K-581/K-582 class (an error body that misinforms rather than informs). It
  # predated K-1028 and that SHAPE fix deliberately left it, so this is the same
  # defect answered in its own wave. The wording is the one this demo had already
  # chosen for the identical case one line down: {WireArguments.party_size}
  # answers a zero party "party_size must be >= 1", and the fleet's other integer
  # guards split the two cases the same way (getgrocery's `delivery_slot_id`,
  # hoteling's `integer`).
  #
  # NOTHING OBSERVABLE ON THE WIRE MOVED, and that is measured rather than
  # assumed: both properties are declared `{type: "integer", minimum: 1}`
  # (`app/controllers/kiosk/bookings_controller.rb:47,:49`) and `input_schema` is
  # validated on every call, so a body carrying `0` is refused a layer earlier
  # and no wire caller ever reached this arm. The descriptor-less path — this
  # class's own `call`, the path the whole guard exists for — is where it was
  # reachable, and a sentence that is only true while the layer in front of it
  # holds is not a true sentence.
  #
  # @return [Array(Integer, nil), Array(nil, OperationResult)]
  def self.identifier(name, raw)
    return [nil, missing(name)] if raw.nil?

    id = WireArguments.whole_number(raw)
    return [nil, bad_request("#{name} must be a whole number >= 1 — got #{raw.inspect}")] if id.nil?
    return [id, nil] if id >= 1

    [nil, bad_request("#{name} must be >= 1")]
  end
  private_class_method :identifier

  def self.bad_request(message)
    OperationResult.refused(code: "bad_request", message: message)
  end
  private_class_method :bad_request

  # Both halves of the double-booking guard answer with the SAME sentence, so an
  # assistant cannot tell (and need not care) which one caught it.
  def self.already_booked(restaurant_table_id, date, time)
    OperationResult.refused(
      code:    "conflict",
      message: "table #{restaurant_table_id} is already booked for #{date} #{time}",
    )
  end
  private_class_method :already_booked
end
