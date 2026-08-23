# frozen_string_literal: true

# THE SHAPE GUARD every hoteling verb opens with — expressed once, as a REFUSAL
# rather than as a rendered response (the {ListAccess} shape tudu settled).
#
# WHY IT EXISTS AT ALL, and why it grew when the SQL went away. Every one of
# these arguments used to be interpolated into a `::integer` / `::date` cast, so
# POSTGRES was the shape check: `property_id: "abc"` raised
# InvalidTextRepresentation, which is not a Kiosk error and so escaped as a raw
# 500 with the PG message attached — for what is plainly a client mistake. That
# was already the K-581/K-582 finding for `booking_id`, and `UuidCheck` was the
# answer; these are the same finding for the other three argument types.
#
# ActiveRecord does not raise on junk — it CASTS. `where(property_id: "abc")`
# silently becomes `= 0` and `where(property_id: true)` becomes `= 1`, so
# without this guard `true` would not be an error at all: it would quietly mean
# "property 1". Losing the database's refusal is exactly why the guard has to be
# here, and it is the same argument {ListAccess} makes about uuids.
#
# It is NOT an Operation: it writes nothing. Both halves use it — the query
# handlers directly, the write Operations before they touch a transaction — so
# one malformed-argument sentence serves the whole origin.
module WireArguments
  # The two "where do I get one of these" sentences, written once because three
  # verbs each can produce them: an assistant that mistypes a `property_id` gets
  # the same pointer from `availability`, `hotel_detail` and `reserve_room`.
  HINT_PROPERTY_ID  = "Pass the `property_id` from a properties (or search_hotels) row, verbatim."
  HINT_ROOM_TYPE_ID = "Pass the `room_type_id` from an availability row, verbatim."

  module_function

  # @return [Array(Integer, nil), Array(nil, OperationResult)]
  #
  # `Integer(str, 10)` and not `.to_i`: `.to_i` answers 0 for "abc" and would
  # turn a typo into a lookup for a row that does not exist, which is a
  # DIFFERENT and much quieter wrong answer than a 400. Base 10 is explicit so
  # "0x10" is refused rather than read as 16. A leading/trailing space is
  # tolerated because Postgres tolerated it (`' 1 '::integer` is 1).
  def integer(raw, field:, hint:)
    return [nil, missing(field)] if raw.blank?

    value = begin
      Integer(raw.to_s.strip, 10)
    rescue ArgumentError, TypeError
      nil
    end
    return [value, nil] unless value.nil?

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "#{field} #{raw.to_s.inspect} is not an integer",
      hint:    hint,
    )]
  end

  # The check-in/check-out pair a stay is quoted for: BOTH required, both
  # YYYY-MM-DD.
  #
  # @return [Array(Array(Date, Date), nil), Array(nil, OperationResult)]
  #
  # `Date.iso8601`, not `Date.parse`, and the choice is a wire-parity one rather
  # than taste. These two values used to reach Postgres RAW, so Postgres' date
  # parser drew the accept/reject line: it refused `"nope"`, `""`, `"true"`,
  # `"2026-09-01'; --"` and `["2026-09-01"]`. `Date.parse` accepts the last two
  # (it scans for a date rather than validating a format) and would turn a
  # refusal into a booking; `Date.iso8601` refuses all five, which is the same
  # line Postgres drew and the same one both descriptors state ("date string
  # YYYY-MM-DD"). `hotel_detail` deliberately keeps its own `Date.parse` — that
  # verb has always parsed in Ruby, so its answers are not this guard's to
  # change.
  def stay_dates(check_in, check_out)
    return [nil, missing("check_in")]  if check_in.blank?
    return [nil, missing("check_out")] if check_out.blank?

    dates = begin
      [Date.iso8601(check_in.to_s), Date.iso8601(check_out.to_s)]
    rescue ArgumentError, TypeError
      nil
    end
    return [dates, nil] unless dates.nil?

    # The same sentence `hotel_detail` has always used for the same mistake.
    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "invalid check_in/check_out: #{check_in.to_s.inspect}/#{check_out.to_s.inspect} — " \
               "use YYYY-MM-DD",
    )]
  end

  # ── T-090: A `property_id` THAT ADDRESSES NOTHING IS 404, NOT AN EMPTY LIST ──
  #
  # Spec §9.1's three-way rule, and this is its second branch: an argument that
  # names a SPECIFIC RESOURCE gets `404 not_found` when the resource does not
  # exist, because an empty list would assert it exists and merely has no rows.
  # Two verbs call this — `hotel_detail`, which addresses a property outright,
  # and `availability`, whose room types belong to that one property — and they
  # get the SAME sentence from here, which is the whole reason it lives in this
  # file rather than in either controller. Until today they disagreed: one
  # answered 404 and the other `200 []` for the same unknown id on the same
  # origin, which is the pair that made this Phil's call.
  #
  # NOT a `bad_request`. The value is well-formed and inside its declared type;
  # nothing about the request is malformed. What is absent is the thing it
  # points at, and that distinction is the difference between "fix your call"
  # and "that hotel is not here".
  #
  # @return [OperationResult, nil] a refusal, or nil when the property exists
  def existing_property(property_id)
    return nil if Property.exists?(id: property_id)

    property_not_found(property_id)
  end

  # The refusal itself, with no lookup. `hotel_detail` has ALREADY established
  # the property is absent (its own `pick` came back nil), and paying for a
  # second `SELECT 1` to learn the same thing would be the price of sharing a
  # sentence. This is how the sentence is shared instead.
  def property_not_found(property_id)
    OperationResult.refused(
      code:    "not_found",
      message: "hotel not found: #{property_id}",
      hint:    "call search_hotels (or properties) and pass a `property_id` from a row.",
    )
  end

  # ── K-969: THERE IS NO ROOM-NIGHT IN THE PAST, SO THERE IS NO OFFER EITHER ──
  #
  # Phil, 2026-08-23: «there should be zero availability for past dates. Booking
  # shouldn't be allowed for those.» Both halves come from this one guard, so
  # the read side and the write side cannot come to disagree about where the
  # floor is — the same argument {Seatings} settles for atablefor and
  # {DeliverySlots} for getgrocery.
  #
  # WHAT «PAST» MEANS HERE, STATED RATHER THAN LEFT TO THE READER:
  #
  #   * The unit is the DAY, not the instant. A room-night is sold by the night.
  #   * The clock is the PROPERTY's, not the caller's: hoteling lists Istanbul
  #     hotels, so "today" is today in Europe/Istanbul. A real IANA zone, so DST
  #     is handled; do NOT replace with a fixed offset. This matters — an
  #     assistant calling from UTC-8 at 21:00 is already on hoteling's tomorrow,
  #     and reading the RUNNER's clock would refuse a stay the hotel will sell.
  #   * TODAY IS BOOKABLE, and that is a product statement, not an oversight: a
  #     same-day arrival is an ordinary hotel sale, and hoteling's own check-in
  #     hour is not modelled anywhere, so refusing today would invent a cutoff
  #     nobody declared. getgrocery draws the same line for the same reason
  #     ({WireArguments.past_date} there), and atablefor's rolling horizon
  #     likewise still offers tonight's not-yet-started seatings. What hoteling
  #     does NOT have is getgrocery's second, finer guard (`past_slot`) — it has
  #     no windows within a day to have missed.
  #
  # It is spec §9.1's FIRST branch and not its third: a past `check_in` is
  # outside the verb's DOMAIN, so it is `400 bad_request` naming what IS
  # acceptable, never `200 []`. The empty array is already spoken for on this
  # origin and means one thing — the property exists and is SOLD OUT for those
  # nights — and that is exactly the answer a past date must not be confusable
  # with, since one of the two is worth retrying and the other never will be.
  #
  # WHY THE FLOOR IS NOT A HORIZON. K-968 declined to invent a far end (how far
  # ahead this operator sells is a product decision nobody has taken) and this
  # does not take it either. The NEAR end needs no such call: nobody sells a
  # night that has already happened.
  ZONE_NAME = "Europe/Istanbul"

  # The property-locale ActiveSupport::TimeZone (Europe/Istanbul).
  def zone
    @zone ||= Time.find_zone!(ZONE_NAME)
  end

  # "Today" in the property's locale — the floor every dated surface reads.
  def today
    zone.now.to_date
  end

  # @param check_in [Date] the first night asked for
  # @return [OperationResult, nil] a refusal, or nil when the stay is bookable
  def past_stay(check_in)
    floor = today
    return nil if check_in >= floor

    OperationResult.refused(
      code:    "bad_request",
      message: "check_in #{check_in.iso8601} is in the past — hoteling sells room-nights from " \
               "#{floor.iso8601} onwards (Europe/Istanbul)",
      hint:    "pass #{floor.iso8601} or a later check_in; today IS bookable (a same-day arrival " \
               "is an ordinary room-night). An EMPTY availability list means the hotel is sold " \
               "out for those nights, which is a different answer from this one.",
    )
  end

  # ── K-968: A STAY NOBODY CAN PRICE IS A 400, NOT A 500 ──────────────────
  #
  # Found by K-773's standing hostile-shape probes on the day they were built,
  # which is the point of having them. `check_in: "0000-01-01"` is a perfectly
  # well-formed ISO date — `format: "date"` accepts it, {#stay_dates} parses it,
  # `check_out > check_in` holds — and the 739,000-night stay it asks for prices
  # at 5,922,168,000 cents. `bookings.total_cents` is a 4-byte `integer`, so the
  # insert raised `ActiveModel::RangeError` and the wire answered
  # `500 action_failed`: a crash, for an argument a client simply got wrong.
  #
  # THE BOUND IS THE COLUMN'S, NOT A POLICY. This deliberately does not invent a
  # booking horizon — how far ahead this operator sells, and for how long, is a
  # product decision nobody has taken and this guard has no business taking. It
  # refuses exactly what cannot be REPRESENTED, so every stay that used to work
  # still works and only the ones that used to crash are refused.
  #
  # @return [OperationResult, nil] a refusal, or nil when the total fits
  MAX_TOTAL_CENTS = 2_147_483_647 # PostgreSQL `integer`

  def priceable_total(total_cents, nights)
    return nil if total_cents <= MAX_TOTAL_CENTS

    OperationResult.refused(
      code:    "bad_request",
      message: "a #{nights}-night stay totals #{total_cents} cents, more than this operator can " \
               "book in one reservation (max #{MAX_TOTAL_CENTS})",
      hint:    "book a shorter stay — check_in and check_out are the first night and the " \
               "checkout day, so their distance is the number of nights charged.",
    )
  end

  # The sentence the raw handlers raised for an absent argument, unchanged. An
  # argument that is PRESENT but null or empty now lands here too: it used to
  # reach Postgres as `''::integer` / `''::date` and come back a 500.
  def missing(field)
    OperationResult.refused(code: "bad_request", message: "missing field: #{field}")
  end
end
