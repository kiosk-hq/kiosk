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

  # The sentence the raw handlers raised for an absent argument, unchanged. An
  # argument that is PRESENT but null or empty now lands here too: it used to
  # reach Postgres as `''::integer` / `''::date` and come back a 500.
  def missing(field)
    OperationResult.refused(code: "bad_request", message: "missing field: #{field}")
  end
end
