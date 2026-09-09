# frozen_string_literal: true

# ── The clock a todo is READ on ─────────────────────────────────────────────
#
# tudu is the one demo in the fleet whose service place is not an address. A
# table is served at the restaurant, a room-night at the property, a delivery at
# the customer's door -- but a reminder is "served" wherever the person reading
# it happens to be, and a SHARED list has two of those people. "Tomorrow at two"
# is said by one of them and read by the other, and there is no single
# wall-clock string that is correct for both.
#
# So the rule comes out as: the stored value is an absolute INSTANT, and every
# rendering is relative to WHOEVER IS READING. That is what `Kiosk-Timezone` is
# for -- the caller declares its human's clock and the row comes back on it.
#
# WHEN THE CALLER DECLARES NOTHING, this household's own clock answers, and the
# row SAYS SO in its `timezone` field. That is a declared default and not a
# guess: it is the only place a constant appears in this file, and it is never
# what a caller that DID declare a zone gets.
#
# WHY THIS IS A CONSTANT AND NOT A COLUMN, which is the opposite of what the
# other demos do and is not an oversight. Elsewhere the zone belongs to a
# RESOURCE -- this restaurant, this property, this served district -- because
# the service happens at a place that resource names. Here the service happens
# at the READER, and a reader is not a row in this database: it is whoever is
# holding the request. There is nothing to put a column on. The constant below
# is the fallback for a caller that told us nothing, and nothing else.
module ReaderClock
  # The household's own clock -- the DECLARED fallback for a caller that
  # declares none. A real IANA zone, so DST is handled; do NOT replace it with a
  # fixed offset.
  DEFAULT_ZONE_NAME = "Europe/Lisbon"

  # An RFC 3339 timestamp ENDS in its offset: `Z`, or `±HH:MM` (`±HHMM` and
  # `±HH` are the other legal spellings). This is what tells a value that
  # declares its instant from one that only looks like it does.
  OFFSET_SUFFIX = /(?:[Zz]|[+-]\d{2}(?::?\d{2})?)\z/

  module_function

  def default_zone
    @default_zone ||= Time.find_zone!(DEFAULT_ZONE_NAME)
  end

  # The zone THIS request is answered on: the caller's declared one, or the
  # household's when it declared none. The row publishes whichever it was, so a
  # reader can always tell.
  def zone
    Kiosk::Server::CurrentRequest.timezone || default_zone
  end

  # Is this wire value an INSTANT -- an RFC 3339 timestamp carrying its offset?
  #
  # A `date-time` field takes RFC 3339, and RFC 3339 REQUIRES the offset, so a
  # value without one is not a value of the declared type at all. It is refused
  # rather than completed from any clock, and here that matters more than
  # anywhere else in the fleet: a due date completed on the WRITER's clock is
  # read by somebody else on theirs, and the two disagree with nothing on the
  # wire to say so.
  def zoneless?(raw)
    !OFFSET_SUFFIX.match?(raw.to_s)
  end

  # A wire `due_at` as an instant, in TWO steps that do two different jobs --
  # the same pair every origin in this fleet uses for a `date-time` argument.
  #
  #   1. stdlib `Time.iso8601` is the SHAPE gate and its value is discarded: it
  #      accepts exactly the full ISO 8601 date-time form, so "banana",
  #      "next tuesday", "12345" and a bare "2026-09-14" all raise here.
  #      {ActiveSupport::TimeZone#iso8601} on its own accepts the last two, and
  #      a malformed deadline that becomes a plausible one is worse than one
  #      refused by name.
  #   2. `zone.iso8601` computes the VALUE. The value carries its own offset by
  #      then, so this resolves ONE absolute instant whatever zone is handed in.
  #
  # @raise [ArgumentError, TypeError] on anything that is not an ISO 8601 instant
  def parse(raw, in_zone = default_zone)
    str = raw.to_s
    Time.iso8601(str)
    in_zone.iso8601(str)
  end

  # An instant as this demo PUBLISHES it, on the READER's clock, as a String.
  #
  # A String and not a Time: an `ActiveSupport::TimeWithZone` renders through
  # `Time.zone` and the JSON encoder's `time_precision`, so the published bytes
  # would be the app's configuration talking rather than this file.
  def publish(time, in_zone = zone)
    time&.in_time_zone(in_zone)&.iso8601
  end

  # The deadline said out loud, with the clock it is written on named beside it
  # -- "Tue 8 Sep, 14:00 (Europe/Istanbul)". The field a human actually hears is
  # this one, and a bare "14:00" is a wall clock with no clock named.
  def label(time, in_zone = zone)
    return nil if time.nil?

    local = time.in_time_zone(in_zone)
    "#{local.strftime("%a %-d %b, %H:%M")} (#{in_zone.name})"
  end
end
