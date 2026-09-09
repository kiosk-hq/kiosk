# frozen_string_literal: true

# ── The salon's clock — the one place stylish says which zone it means ───────
# stylish renders its service AT THE SALON: a chair, at an address, at an hour.
# So every wall-clock question this demo answers is answered on THAT SALON's
# clock — `salons.timezone`, a recorded column, read off the salon being booked
# and never off the origin. One operator may run salons in more than one city,
# and the answer read off the origin is right only for as long as it does not.
#
# `Europe/Paris` survives here as the ORIGIN DEFAULT: what backfills that
# column, and what dates a published example where no salon has been addressed
# yet. It is not what a request is answered on.
#
# WHY IT EXISTS. Stdlib `Time.iso8601` binds a string carrying NO offset to
# whatever zone the SERVER PROCESS happens to run in. Measured, the same
# "2026-09-14T14:00:00" is `+11:00` under `TZ=Etc/GMT-11` and `-02:00` under
# `TZ=Etc/GMT+2` — thirteen hours apart, from one environment variable nobody
# sets deliberately. Read that way, an operator deploying to a box in another
# zone books the wrong hour, and nothing in the response says which hour it
# understood. So `book_appointment` reads its `slot` through here instead.
#
# ZONE: a real IANA zone, so CET (UTC+1, winter) and CEST (UTC+2, summer) are
# both handled across DST. Do NOT replace it with a fixed offset.
module SalonClock
  # The ORIGIN's default locale — what `salons.timezone` is backfilled from,
  # and the clock a published example is dated on.
  DEFAULT_ZONE_NAME = "Europe/Paris"

  # An RFC 3339 timestamp ENDS in its offset: `Z`, or `±HH:MM` (`±HHMM` and
  # `±HH` are the other legal spellings). This is what tells a value that
  # declares its instant from one that only looks like it does.
  OFFSET_SUFFIX = /(?:[Zz]|[+-]\d{2}(?::?\d{2})?)\z/

  module_function

  # The ORIGIN default as an ActiveSupport::TimeZone (Europe/Paris).
  def default_zone
    @default_zone ||= Time.find_zone!(DEFAULT_ZONE_NAME)
  end

  # The clock the salon with this id books on, or the origin default when the
  # id addresses nothing — a caller that named a salon nobody has is refused by
  # name before this matters.
  def zone_for(salon_id)
    Salon.where(id: salon_id).pick(:timezone)&.then { |name| Time.find_zone!(name) } || default_zone
  end

  # Is this wire value an INSTANT — an RFC 3339 timestamp carrying its offset?
  #
  # A `date-time` field takes RFC 3339, and RFC 3339 REQUIRES the offset, so a
  # value without one is not a value of the declared type at all. It is refused
  # rather than completed from any clock: one declared type admits one
  # spelling, exactly as for a calendar date. Completing it at the salon was
  # the previous behaviour and it is wrong for the caller that DID declare its
  # own clock — an appointment booked an hour off is unrecoverable, a refusal
  # naming its remedy is not.
  def zoneless?(raw)
    !OFFSET_SUFFIX.match?(raw.to_s)
  end

  # A wire `slot` as an instant, parsed in TWO steps that do two different jobs.
  #
  #   1. stdlib `Time.iso8601` is the SHAPE gate and nothing else — its return
  #      value is deliberately discarded, because that value is the bug. It
  #      accepts exactly the full ISO 8601 date-time form, so "banana",
  #      "next tuesday", "12345" and a bare "2026-09-14" all raise here. They
  #      must: {ActiveSupport::TimeZone#iso8601} on its own accepts the last two
  #      (measured — "12345" resolves to 2012-12-10, "2026-09-14" to midnight),
  #      and a malformed slot that becomes a plausible appointment is worse than
  #      one that is refused by name.
  #   2. `zone.iso8601` computes the VALUE. The value carries its own offset by
  #      then — {.zoneless?} is what the caller refuses on — so this resolves
  #      one absolute instant, and the zone decides only how it is READ BACK.
  #
  # @param raw [Object] the wire value, whatever arrived
  # @param zone [ActiveSupport::TimeZone] the SALON's, from {.zone_for}
  # @return [ActiveSupport::TimeWithZone] the instant, on that salon's clock
  # @raise [ArgumentError, TypeError] on anything that is not an ISO 8601 instant
  def parse_slot(raw, zone = default_zone)
    str = raw.to_s
    Time.iso8601(str)
    zone.iso8601(str)
  end

  # An instant as this demo PUBLISHES it: on the salon's clock, as a String.
  #
  # EVERY verb that answers with an appointment instant goes through here —
  # `book_appointment`'s confirmation and its refusals, `my_appointments`,
  # `salon_calendar` — so the demo cannot spell one instant two ways for one
  # salon.
  # {BookAppointmentOperation.example_slot} computes its example on the salon's
  # clock so that the example and the response agree; this method is what makes
  # the response side of that true. Rendered off the record instead, a value
  # goes out through `Time.zone` and the agreement is lost.
  #
  # A String, not a Time, and that is the second half of the pin: an
  # `ActiveSupport::TimeWithZone` renders through `Time.zone` and the JSON
  # encoder's `time_precision`, so the published BYTES would be set by the app's
  # configuration rather than by this file. `.iso8601` on a zone-resolved value
  # is the same bytes here, in CI and on a box in another zone.
  #
  # The zone is the SALON's, handed in: two appointments in one answer may be at
  # salons in two cities, and each row is rendered where its own chair is.
  def publish(time, zone = default_zone)
    time&.in_time_zone(zone)&.iso8601
  end
end
