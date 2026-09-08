# frozen_string_literal: true

# THE SHAPE GUARDS atablefor's verbs open with — expressed once, as REFUSALS
# rather than as rendered responses, so both halves of the wire can use them:
# the query handler directly, the write Operations before they touch a
# transaction. They are NOT Operations: they write nothing.
#
# `party_size` is the one guard on this origin genuinely shared between a query
# (`availability`) and an action (`book_table`): a party that cannot be shown a
# table cannot be booked one either, and one sentence for both is one sentence
# that cannot drift.
module WireArguments
  module_function

  # PostgreSQL `integer` — the width of `bookings.party_size`, the column a
  # confirmed party is WRITTEN to, and of `restaurant_tables.capacity`, the
  # column it is COMPARED against. THE BOUND IS THE COLUMN'S AND NOT A POLICY:
  # it refuses exactly what cannot be REPRESENTED and invents no house limit on
  # party size, so every party a table can seat is still seatable and only the
  # ones that would CRASH are refused.
  MAX_INT4 = 2_147_483_647

  # The party a caller wants seated: SHAPE first, then RANGE, one answer per
  # thing that can be wrong.
  #
  # The {MAX_INT4} arm is the one that is not obvious. Without it a well-formed
  # `party_size: 2_147_483_648` walks into
  # `RestaurantTable.where(capacity.gteq(party_size))` and ActiveRecord raises
  # `ActiveModel::RangeError` CASTING the comparison — HTTP 500 for an argument
  # a client simply got wrong. The two identifiers next door reach ActiveRecord
  # as EQUALITY predicates, which answer zero rows instead of raising; it is the
  # COMPARISON that casts, and `party_size` is the only argument that reaches one.
  #
  # Do NOT reduce this to `raw.to_i`: `true`/`[]`/`{}` have no `to_i` at all and
  # raise, and `1.5.to_i` is 1, so a fractional party would be seated as a party
  # of ONE rather than refused. No wire call can reach either mistake, but
  # {BookTableOperation} is callable with no descriptor in front of it, and a
  # layer that only holds while the layer in front of it holds is not a layer.
  #
  # @return [Array(Integer, nil), Array(nil, OperationResult)]
  def party_size(raw)
    size = whole_number(raw)
    if size.nil?
      return [nil, OperationResult.refused(
        code:    "bad_request",
        message: "party_size must be a whole number >= 1 — got #{raw.inspect}",
      )]
    end
    if size < 1
      return [nil, OperationResult.refused(code: "bad_request", message: "party_size must be >= 1")]
    end
    if size > MAX_INT4
      return [nil, OperationResult.refused(
        code:    "bad_request",
        message: "party_size must be <= #{MAX_INT4} — got #{size}",
      )]
    end

    [size, nil]
  end

  # JSON Schema's `integer`, in Ruby — and nothing looser.
  #
  # NOT `is_a?(Integer)`: draft 2020-12 defines `integer` NUMERICALLY, so
  # `{"party_size": 2.0}` is a VALID integer and json_schemer accepts it. A bare
  # class test would refuse a call the published schema allows.
  #
  # The cost: a STRING is not a party, so `availability` works only because its
  # declared `{type: "integer"}` makes {Kiosk::Server::ArgumentDecoder} coerce
  # `?party_size=2` first. The query half's second layer therefore sits
  # DOWNSTREAM of the descriptor; the action half's does not.
  #
  # @return [Integer, nil] nil when `raw` is not a whole number
  def whole_number(raw)
    return raw if raw.is_a?(Integer)
    return nil unless raw.is_a?(Float) && raw.finite?

    raw == raw.truncate ? raw.truncate : nil
  end

  # The sentence `availability` answers for a party_size it was not GIVEN at all.
  def missing_party_size
    OperationResult.refused(code: "bad_request", message: "missing param: party_size")
  end

  # ── AN INVALID FILTER VALUE IS A TYPED 400, NEVER AN EMPTY LIST ───────────
  #
  # A value this origin cannot serve is refused 400 with the servable ones
  # named, because `200 []` is indistinguishable from an honest sell-out. The
  # empty list survives for that honest case only.
  #
  # `time` is a closed set and is also declared as an `enum`, so this guard is
  # defence in depth for the descriptor-less Operations path. `date` needs a
  # guard and always will: the horizon rolls forward daily, so no `enum` written
  # at declaration time can name it.

  # A seating TIME the roster actually offers.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def seating_time(raw)
    time = raw.to_s
    return [time, nil] if time.empty? || Seatings::TIMES.include?(time)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "time #{time.inspect} is not a seating — this restaurant seats at " \
               "#{Seatings::TIMES.join(", ")}",
    )]
  end

  # The "currently …" tail both DB-derived refusals end in. It is a method and
  # not a `join` at each site because `[].join(", ")` is `""`, leaving «… serves
  # — currently » — a promise of a set with nothing after it. A fresh operator
  # install has exactly that empty set, so it is the first refusal an assistant
  # sees there. "none" tells the assistant retrying is pointless; a dropped
  # clause leaves it unable to tell an empty set from a set it is not in.
  #
  # @return [String]
  def served_list(values)
    values.empty? ? "none" : values.join(", ")
  end

  # A seating DATE inside the rolling upcoming horizon. The valid values are
  # NAMED in the refusal, so an assistant recovers without a second fetch.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def seating_date(raw, upcoming)
    date = raw.to_s
    dates = upcoming.map { |d, _t| d.iso8601 }.uniq
    return [date, nil] if date.empty? || dates.include?(date)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "date #{date.inspect} is not among the upcoming seatings — " \
               "currently #{served_list(dates)}",
    )]
  end

  # A NEIGHBOURHOOD the aggregator actually serves.
  #
  # The set is DB-derived — an operator adds one by inserting a restaurant — so
  # no static `enum` can name it and this guard is the only place the refusal
  # can live. An unserved value is outside its DOMAIN (§9.1's first branch), not
  # an empty result; `200 []` is what a served neighbourhood fully booked gets.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def neighborhood(raw, served)
    value = raw.to_s
    return [value, nil] if value.empty? || served.include?(value)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "neighborhood #{value.inspect} is not one this aggregator serves — " \
               "currently #{served_list(served)}",
    )]
  end

  # The booking `cancel_booking` acts on: PRESENT, then shaped like an id.
  #
  # It must stay even though `format: "uuid"` refuses both classes on the wire
  # first, because ActiveRecord does not refuse a malformed uuid — it CASTS it
  # to NULL, so `where(id: junk)` matches no row and {CancelBookingOperation},
  # callable with no descriptor in front of it, would answer a typo as an
  # OWNERSHIP refusal (403) rather than a shape one (400). A well-formed but
  # foreign id still gets the 403.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def booking_id(raw)
    if raw.blank?
      return [nil, OperationResult.refused(code: "bad_request", message: "missing field: booking_id")]
    end
    return [raw, nil] if UuidCheck.valid?(raw)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "booking_id #{raw.to_s.inspect} is not a uuid — pass the `booking_id` " \
               "that book_table returned (also listed by my_bookings)",
    )]
  end
end
