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
  # column it is COMPARED against. THE BOUND IS THE COLUMN'S AND NOT A POLICY
  # (K-968's rule, K-1047's class): it refuses exactly what cannot be
  # REPRESENTED and invents no house limit on party size, so every party that
  # used to be seatable still is and only the ones that used to CRASH are
  # refused.
  MAX_INT4 = 2_147_483_647

  # The party a caller wants seated.
  #
  # SHAPE AND RANGE, in that order — THREE answers, one per thing that can be
  # wrong, and they are listed here because two of them are new since K-1027:
  #
  #   * ABSENT (`nil`) → the SHAPE sentence, "party_size must be a whole number
  #     >= 1 — got nil", because {#whole_number} answers nil for a nil;
  #   * GIVEN, WRONG SHAPE (`1.5`, `"abc"`, `true`, `[]`, `{}`) → the same SHAPE
  #     sentence with the value echoed;
  #   * GIVEN, OUT OF RANGE (`0` or a negative) → the RANGE sentence,
  #     "party_size must be >= 1".
  #   * GIVEN, TOO LARGE TO STORE (past {MAX_INT4}) → the ceiling sentence, and
  #     it is K-1047: this arm did not exist and neither did the descriptor's
  #     `maximum`, so a well-formed `party_size: 2_147_483_648` walked into
  #     `RestaurantTable.where(capacity.gteq(party_size))` and ActiveRecord
  #     raised `ActiveModel::RangeError` CASTING the comparison — HTTP 500 for
  #     an argument a client simply got wrong, on BOTH surfaces at once, with
  #     the runtime's own class name in the body. Measured on a booted origin,
  #     and probed by this demo's HostileArgShapes beat so it stays measured.
  #     NOTE the asymmetry with the two identifiers next door: they reach
  #     ActiveRecord as EQUALITY predicates, where an out-of-range value is
  #     answered with zero rows rather than a raise. It is the COMPARISON that
  #     casts, and `party_size` is the only wire argument that reaches one.
  #
  # WHETHER THE ARGUMENT WAS GIVEN AT ALL is a fourth question and this guard
  # does not answer it — `availability` asks it one layer up, answering
  # {#missing_party_size} for a missing key before ever reaching here
  # (`Kiosk::DiningRoomController#availability`). `book_table` does not ask it:
  # `party_size` is `required` in its `input_schema`, so no wire body can omit
  # it, and a descriptor-less `BookTableOperation.call(party_size: nil, …)`
  # lands on the SHAPE arm above. {BookTableOperation.identifier} does carry a
  # `nil` arm of its own ("missing param: …") because its ids have no such
  # question-asking verb in front of them.
  #
  # THIS PARAGRAPH USED TO SAY THE OPPOSITE, and the correction is K-1032: while
  # the body read `size = raw.to_i`, `nil.to_i` was 0, so an absent party really
  # did get the RANGE sentence a zero gets and `availability` really was the only
  # verb that distinguished the two. K-1027 replaced the coercion with
  # {#whole_number} and its own shape refusal, which split the two cases apart
  # and left the sentence about them behind by one commit.
  #
  # The declared `{type: "integer", minimum: 1}` refuses a zero party on the wire
  # first, so this is defence in depth; it stays because {BookTableOperation} is
  # reachable with no descriptor in front of it and must not open a transaction
  # on a party of zero.
  #
  # THE SHAPE IS THE SCHEMA'S, NOT `.to_i`'s (K-1027 — getgrocery's K-1020 and
  # K-1025 defect, one demo over and WEAKER). This line read a bare `raw.to_i`,
  # and MEASURED over that row's probe set it got two things wrong at once:
  #
  #   * `true`, `false`, `[]`, `{}`, `[1]` and `{"a" => 1}` have no `to_i` AT
  #     ALL, so each raised `NoMethodError` — a `500 action_failed` on the wire
  #     for a value the published descriptor already forbids;
  #   * `1.5.to_i` is 1, so a fractional party came out of this line INSIDE the
  #     declared range and was seated as a party of ONE rather than refused.
  #
  # (`"abc"`, `nil` and `"0x10"` were 0 and the range arm below caught them, and
  # `2.0` was 2 — which it still is, see {#whole_number}.)
  #
  # THE COMMENT ABOVE IS WHY THAT HAD TO BE FIXED RATHER THAN NOTED. Nothing on
  # the wire could reach it: `book_table` is `kind :action`, so its JSON body is
  # validated against `input_schema` first, and `availability` is `kind :query`,
  # so {Kiosk::Server::ArgumentDecoder}'s `Integer(v, 10)` refuses a non-integer
  # spelling before the handler runs. The path this guard SAYS it exists for is
  # the descriptor-less one — {BookTableOperation} is an ordinary class with an
  # ordinary `call` — and that is precisely the path on which nothing has
  # coerced the argument, so it is precisely where a `.to_i` turned a hostile
  # shape into a 500 and `1.5` into a party of one. A layer that only holds
  # while the layer in front of it holds is not a second layer at all.
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
  # NOT `is_a?(Integer)`, and the difference is measured rather than assumed:
  # draft 2020-12 defines `integer` NUMERICALLY, not by wire type, so
  # `{"party_size": 2.0}` is a VALID integer and json_schemer accepts it —
  # re-measured against THIS demo's own bundle (json_schemer 2.5.0) and not
  # inherited from the sibling row that first measured it (K-1020). A bare class
  # test here would therefore refuse a call the published schema allows, which is
  # the one way this guard could get the story wrong in the other direction.
  # JSON parsing yields Integer or Float and nothing else, so those are the two
  # cases; every other type — nil, true/false, String, Array, Hash — and every
  # fractional or non-finite Float is not a party.
  #
  # DELIBERATELY THE SAME HELPER getgrocery grew for `qty` and `delivery_slot_id`
  # (K-1020, K-1025) and deliberately NOT hoteling's `Integer(raw.to_s, 10)`
  # spelling: that one is for arguments the query decoder has ALREADY turned into
  # integers, and `party_size` is also reached with no decoder in front of it.
  #
  # WHAT THAT COSTS, MEASURED rather than left for the next reader to trip over:
  # a STRING is not a party, so `availability` works only because its declared
  # `{type: "integer"}` makes {Kiosk::Server::ArgumentDecoder} coerce
  # `?party_size=2` to `2` before the handler runs. Drop that declaration and
  # this guard refuses the legal call along with the hostile ones (watched, and
  # restored). That is the correct trade for a layer whose whole job is to be
  # the schema's `integer` and nothing looser — but it means the query half's
  # second layer sits DOWNSTREAM of the descriptor rather than independent of it,
  # which the action half's does not.
  #
  # @return [Integer, nil] nil when `raw` is not a whole number
  def whole_number(raw)
    return raw if raw.is_a?(Integer)
    return nil unless raw.is_a?(Float) && raw.finite?

    raw == raw.truncate ? raw.truncate : nil
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

  # The "currently …" tail both DB-DERIVED refusals end in, and the reason it is
  # a method rather than a `join` at each site (K-1231).
  #
  # `[].join(", ")` is `""`, so the sentence came to rest as «… is not one this
  # aggregator serves — currently » — a promise of a set with nothing after it,
  # which is WORSE than no clause at all: an assistant parsing the refusal for
  # the values it may retry with gets an empty promise rather than an absence.
  # And the empty set is not a corner: an origin with no restaurants, or none
  # with an upcoming seating, is exactly the state a fresh operator install is
  # in, so this is the FIRST refusal a new operator's assistant sees.
  #
  # "none" rather than dropping the clause, because the two say different things.
  # Dropping it leaves the assistant unable to tell "there is a set and I am not
  # in it" from "there is no set"; "none" says the second, and says that
  # retrying with another value is pointless.
  #
  # @return [String]
  def served_list(values)
    values.empty? ? "none" : values.join(", ")
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
               "currently #{served_list(dates)}",
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
               "currently #{served_list(served)}",
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
