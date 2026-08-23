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

  # The party a caller wants seated.
  #
  # RANGE ONLY. Whether the argument was GIVEN is asked separately, by
  # `availability` — the only verb that distinguishes the two, since `book_table`
  # has always answered an absent party the way it answers a zero one.
  #
  # The declared `{type: "integer", minimum: 1}` refuses a zero party on the wire
  # first, so this is defence in depth; it stays because {BookTableOperation} is
  # reachable with no descriptor in front of it and must not open a transaction
  # on a party of zero.
  #
  # @return [Array(Integer, nil), Array(nil, OperationResult)]
  def party_size(raw)
    size = raw.to_i
    return [size, nil] if size >= 1

    [nil, OperationResult.refused(code: "bad_request", message: "party_size must be >= 1")]
  end

  # The sentence `availability` answers for a party_size it was not GIVEN at all.
  # It lives here so both of that verb's party_size answers sit beside the one it
  # shares with `book_table`, which uses neither.
  def missing_party_size
    OperationResult.refused(code: "bad_request", message: "missing param: party_size")
  end

  # ── K-717: AN INVALID FILTER VALUE IS A TYPED 400, NEVER AN EMPTY LIST ────
  #
  # The house rule for every filter-shaped query in the fleet: a value this
  # origin cannot serve is refused 400 with the servable ones named, because
  # `200 []` is indistinguishable from an honest sell-out. The empty list
  # survives for that honest case only.
  #
  # WHICH LAYER ANSWERS. `time` is a closed set, so it is declared as an `enum`
  # and the schema layer — validated on every 0.4 call — refuses `time=18:00`
  # before the handler runs; {#seating_time} is kept as defence in depth for the
  # Operations, which reach these guards with no descriptor in between. `date`
  # needs a guard and always will: the horizon rolls forward daily, so no `enum`
  # written at declaration time can name it, and `format: "date"` can only say
  # the string is a calendar date.

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

  # A seating DATE inside the rolling upcoming horizon. The valid values are
  # NAMED in the refusal, so an assistant recovers without a second fetch
  # (K-717).
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def seating_date(raw, upcoming)
    date = raw.to_s
    dates = upcoming.map { |d, _t| d.iso8601 }.uniq
    return [date, nil] if date.empty? || dates.include?(date)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "date #{date.inspect} is not among the upcoming seatings — " \
               "currently #{dates.join(", ")}",
    )]
  end

  # A NEIGHBOURHOOD the aggregator actually serves.
  #
  # The set is DB-DERIVED — an operator adds one by inserting a restaurant — so
  # no static `enum` in `input_schema` can name it and this guard is the only
  # place the refusal can live (T-090). It names the served neighbourhoods
  # exactly as {#seating_time} and {#seating_date} name theirs.
  #
  # It is a FILTER over a collection in the §9.1 sense, so why not `200 []`?
  # Because the value is outside its DOMAIN, which is §9.1's first branch. The
  # third branch is what a SERVED neighbourhood with every table taken gets.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def neighborhood(raw, served)
    value = raw.to_s
    return [value, nil] if value.empty? || served.include?(value)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "neighborhood #{value.inspect} is not one this aggregator serves — " \
               "currently #{served.join(", ")}",
    )]
  end

  # The booking `cancel_booking` acts on: PRESENT, then shaped like an id.
  #
  # Two refusals, and the split is BEHAVIOUR. `blank?` answers the first: an
  # absent key, an explicit `null`, `""`, `"   "` — and `false`, because
  # `false.blank?` is true — are all "you did not give me one". Anything else
  # that is not a uuid is "you gave me the wrong thing", and that sentence names
  # where a right one comes from.
  #
  # The declared `format: "uuid"` refuses both classes on the wire first, so this
  # is defence in depth — but it must stay, because ActiveRecord does not refuse
  # a malformed uuid, it CASTS it to NULL (K-654): `where(id: junk)` then matches
  # no row, so {CancelBookingOperation}, which is callable with no descriptor in
  # front of it, would answer a typo as an OWNERSHIP refusal (403) rather than a
  # shape one (400). A well-formed but foreign id still gets the 403, so the
  # shape check never softens the ownership answer.
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
