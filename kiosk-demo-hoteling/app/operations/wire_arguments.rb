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

  # @return [Array(Integer, nil), Array(nil, OperationResult)]
  #
  # `Integer(str, 10)` and not `.to_i`: `.to_i` answers 0 for "abc", turning a
  # typo into a much quieter wrong answer than a 400. Base 10 is explicit so
  # "0x10" is refused rather than read as 16; surrounding space is tolerated.
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

  # An argument that is absent, or present but null/empty.
  def missing(field)
    OperationResult.refused(code: "bad_request", message: "missing field: #{field}")
  end
end
