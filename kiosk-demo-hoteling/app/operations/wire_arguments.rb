# frozen_string_literal: true

# THE SHAPE GUARD every hoteling verb opens with — expressed once, as a REFUSAL
# rather than as a rendered response (the {ListAccess} shape tudu settled).
#
# It exists because ActiveRecord does not raise on junk — it CASTS.
# `where(property_id: "abc")` silently becomes `= 0` and
# `where(property_id: true)` becomes `= 1`, so without this guard `true` would
# quietly mean "property 1" rather than being an error. Postgres refused those
# outright, and recovering that refusal is the job (K-581/K-582 is the same
# finding for `booking_id`).
#
# NOT an Operation: it writes nothing. Both halves use it — the query handlers
# directly, the write Operations before they touch a transaction.
module WireArguments
  # The two "where do I get one of these" sentences, written once so
  # `availability`, `hotel_detail` and `reserve_room` all give the same pointer.
  HINT_PROPERTY_ID  = "Pass the `property_id` from a properties (or search_hotels) row, verbatim."
  HINT_ROOM_TYPE_ID = "Pass the `room_type_id` from an availability row, verbatim."

  module_function

  # PostgreSQL `integer` — the width of every column a value out of {#integer}
  # is compared against or stored in: `properties.stars`, the cheapest-rate
  # cents `max_price_cents` filters on, and `bookings.total_cents`.
  #
  # THE BOUND IS THE COLUMN'S AND NOT A POLICY (K-968's rule): it refuses
  # exactly what cannot be REPRESENTED and invents no star ceiling and no
  # nightly-rate ceiling. Named MAX_INT4 rather than for any one of those
  # columns because three of them share it, and because the two sibling demos'
  # guards carry the same constant under the same name — the three helpers
  # converge here even though their coercions deliberately do not (getgrocery
  # and atablefor use {whole_number} for arguments that reach them with no
  # decoder in front; hoteling's integers arrive as query strings).
  MAX_INT4 = 2_147_483_647

  # @param max [Integer, nil] the ceiling this argument's column can hold; nil
  #   for a value that reaches no column at all.
  # @return [Array(Integer, nil), Array(nil, OperationResult)]
  #
  # `Integer(str, 10)` and not `.to_i`: `.to_i` answers 0 for "abc", turning a
  # typo into a much quieter wrong answer than a 400. Base 10 is explicit so
  # "0x10" is refused rather than read as 16; surrounding space is tolerated.
  #
  # SHAPE, THEN MAGNITUDE — and the second arm is T-125, the axis this helper
  # did not have while both its siblings did. It is HARDENING and closes no
  # present defect: MEASURED at head inside this bundle, hoteling was safe from
  # K-1047's class by a COINCIDENCE of its call sites rather than by anything
  # written here.
  #
  #   * `min_stars` reaches `Property.arel_table[:stars].gteq(min_stars)`, which
  #     is the RAISING shape — `gteq(2**31)` → `ActiveModel::RangeError:
  #     2147483648 is out of range for ActiveModel::Type::Integer with limit 4
  #     bytes` — and was safe only because its descriptor declares `maximum: 5`
  #     and schema validation is unconditional for queries as well as actions.
  #   * `max_price_cents` had NO declared maximum and reaches
  #     `Property.from_price_cents.lteq(max_price_cents)`, which does not raise
  #     — but only because {Property.from_price_cents} is an
  #     `Arel::Nodes::Grouping` wrapping a correlated subquery and therefore
  #     carries no int4 type, so the literal is inlined into the SQL. Denormalise
  #     that cheapest-rate subquery into a real int4 column — an ordinary
  #     performance move — and the identical query becomes a 500.
  #
  # A guard that holds only while a descriptor elsewhere holds is not a second
  # layer at all (the K-1020/K-1025/K-1027 argument, three demos deep), so the
  # ceiling is asked HERE and mirrored in the descriptor rather than left to it.
  #
  # WHO OMITS `max:`, and why — because an omission nobody reasoned about is how
  # `max_price_cents` got here. `limit` reaches no column (it becomes `.limit()`
  # and is CLAMPED into 1..HOTELING_SEARCH_MAX), and its description publishes
  # that every integer `limit` is adjusted rather than refused. `property_id`
  # and `room_type_id` reach ActiveRecord as EQUALITY predicates, where an
  # out-of-range value is absorbed — MEASURED: `Property.where(id: 2**31).first`
  # → nil, no raise — and answers the `404 not_found` spec §9.1's second branch
  # asks for; a ceiling here would turn that into a 400 that also published the
  # column's width. It is the COMPARISON that casts, which is the same line
  # atablefor's `party_size` beat draws for the same reason.
  #
  # There is deliberately no `min:` to match: no argument on this surface has a
  # floor that is this guard's to enforce. `min_stars`' 1 and `max_price_cents`'
  # 0 are POLICY the descriptor declares, a negative id equality-matches nothing
  # and `limit` clamps — so a `min:` keyword would be a parameter nothing passes
  # and no probe exercises.
  def integer(raw, field:, hint:, max: nil)
    return [nil, missing(field)] if raw.blank?

    value = begin
      Integer(raw.to_s.strip, 10)
    rescue ArgumentError, TypeError
      nil
    end
    if value.nil?
      return [nil, OperationResult.refused(
        code:    "bad_request",
        message: "#{field} #{raw.to_s.inspect} is not an integer",
        hint:    hint,
      )]
    end
    return [value, nil] if max.nil? || value <= max

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "#{field} must be <= #{max} — got #{value}",
      hint:    hint,
    )]
  end

  # The check-in/check-out pair a stay is quoted for: BOTH required, both
  # YYYY-MM-DD.
  #
  # @return [Array(Array(Date, Date), nil), Array(nil, OperationResult)]
  #
  # `Date.iso8601`, not `Date.parse`: `Date.parse` SCANS for a date rather than
  # validating a format, so it accepts `"2026-09-01'; --"` and `["2026-09-01"]`
  # and would turn a refusal into a booking. `hotel_detail` keeps its own
  # `Date.parse` — that verb's answers are already published behaviour.
  def stay_dates(check_in, check_out)
    return [nil, missing("check_in")]  if check_in.blank?
    return [nil, missing("check_out")] if check_out.blank?

    dates = begin
      [Date.iso8601(check_in.to_s), Date.iso8601(check_out.to_s)]
    rescue ArgumentError, TypeError
      nil
    end
    return [dates, nil] unless dates.nil?

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "invalid check_in/check_out: #{check_in.to_s.inspect}/#{check_out.to_s.inspect} — " \
               "use YYYY-MM-DD",
    )]
  end

  # ── T-090: A `property_id` THAT ADDRESSES NOTHING IS 404, NOT AN EMPTY LIST ──
  #
  # Spec §9.1's second branch: an argument naming a SPECIFIC RESOURCE gets
  # `404 not_found` when it does not exist, because an empty list would assert
  # the resource exists and merely has no rows. `hotel_detail` and `availability`
  # both address a property, and both get the SAME sentence from here. NOT a
  # `bad_request`: the value is well-formed and inside its declared type — what
  # is absent is the thing it points at.
  #
  # @return [OperationResult, nil] a refusal, or nil when the property exists
  def existing_property(property_id)
    return nil if Property.exists?(id: property_id)

    property_not_found(property_id)
  end

  # The refusal itself, with no lookup: `hotel_detail` has already established
  # the property is absent (its own `pick` came back nil) and should not pay for
  # a second `SELECT 1` to share this sentence.
  def property_not_found(property_id)
    OperationResult.refused(
      code:    "not_found",
      message: "hotel not found: #{property_id}",
      hint:    "call search_hotels (or properties) and pass a `property_id` from a row.",
    )
  end

  # ── K-969: THERE IS NO ROOM-NIGHT IN THE PAST, SO THERE IS NO OFFER EITHER ──
  #
  # One floor for the read side and the write side, so they cannot disagree.
  # What «past» means here:
  #
  #   * The unit is the DAY — a room-night is sold by the night.
  #   * The clock is the PROPERTY's, not the caller's. A real IANA zone, so DST
  #     is handled; do NOT replace it with a fixed offset. An assistant calling
  #     from UTC-8 at 21:00 is already on hoteling's tomorrow, so reading the
  #     RUNNER's clock would refuse a stay the hotel will sell.
  #   * TODAY IS BOOKABLE: a same-day arrival is an ordinary hotel sale, and
  #     hoteling models no check-in hour, so refusing today would invent a
  #     cutoff nobody declared.
  #
  # Spec §9.1's FIRST branch: a past `check_in` is outside the verb's DOMAIN, so
  # `400 bad_request` and never `200 []` — the empty array already means SOLD
  # OUT, and only one of the two is worth retrying. No FAR end is invented: how
  # far ahead this operator sells is a decision nobody has taken.
  ZONE_NAME = "Europe/Istanbul"

  # The property-locale ActiveSupport::TimeZone (Europe/Istanbul).
  def zone
    @zone ||= Time.find_zone!(ZONE_NAME)
  end

  # "Today" in the property's locale — the floor every dated surface reads.
  def today
    zone.now.to_date
  end

  # THE CHECK-IN A PUBLISHED EXAMPLE NAMES (K-972): tomorrow, in the property's
  # own locale. A calendar literal in `example_params`/`example_row` says «copy
  # this verbatim» and ages into a 400 the moment {#past_stay}'s floor passes it;
  # tomorrow rather than {#today} so the example survives the whole day it is
  # read on, in any client's timezone. Read through a proc from the declaration,
  # never called at class-body load — see {Kiosk::Server::SchemaSlots}.
  def example_check_in
    today + 1
  end

  # The checkout day a published example names: a three-night stay from
  # {#example_check_in}, which is what the `example_row` beside it prices.
  def example_check_out
    example_check_in + 3
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
  # A well-formed ISO `check_in` far enough back prices a stay past
  # `bookings.total_cents`, a 4-byte `integer` — the INSERT then raised
  # `ActiveModel::RangeError` and the wire answered `500 action_failed` for an
  # argument a client simply got wrong. THE BOUND IS THE COLUMN'S, NOT A POLICY:
  # it refuses exactly what cannot be REPRESENTED and invents no booking horizon.
  #
  # The ceiling is {MAX_INT4}, declared once at the top of this module: it is the
  # SAME column width `min_stars` and `max_price_cents` are bounded by, and two
  # constants of one value in one file is the drift this demo has already paid
  # for elsewhere (T-125).
  #
  # @return [OperationResult, nil] a refusal, or nil when the total fits
  def priceable_total(total_cents, nights)
    return nil if total_cents <= MAX_INT4

    OperationResult.refused(
      code:    "bad_request",
      message: "a #{nights}-night stay totals #{total_cents} cents, more than this operator can " \
               "book in one reservation (max #{MAX_INT4})",
      hint:    "book a shorter stay — check_in and check_out are the first night and the " \
               "checkout day, so their distance is the number of nights charged.",
    )
  end

  # An argument that is absent, or present but null/empty.
  def missing(field)
    OperationResult.refused(code: "bad_request", message: "missing field: #{field}")
  end
end
