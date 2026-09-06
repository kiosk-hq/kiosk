# frozen_string_literal: true

# ── The salon's clock — the one place stylish says which zone it means ───────
# stylish renders its service AT THE SALON: a chair, at an address, at an hour.
# So every wall-clock question this demo answers is answered on the salon's
# clock, and that clock is named here once — the same shape atablefor's
# `Seatings` and hoteling's `WireArguments` already use for their own service
# places.
#
# WHY IT EXISTS. `book_appointment` used to read its `slot` with stdlib
# `Time.iso8601`, which binds a string carrying NO offset to whatever zone the
# SERVER PROCESS happens to run in. Measured, the same "2026-09-14T14:00:00" is
# `+11:00` under `TZ=Etc/GMT-11` and `-02:00` under `TZ=Etc/GMT+2` — thirteen
# hours apart, from one environment variable nobody sets deliberately — while
# the comment beside it claimed the value was read "in the app's own zone (UTC
# here)". An operator deploying to a box in another zone booked the wrong hour,
# and nothing in the response said which hour it had understood.
#
# ZONE: a real IANA zone, so CET (UTC+1, winter) and CEST (UTC+2, summer) are
# both handled across DST. Do NOT replace it with a fixed offset.
module SalonClock
  # The salon's locale. Combette on Park keeps one chair-side clock, and this
  # is it; a per-salon column is a different demo from this one.
  ZONE_NAME = "Europe/Paris"

  module_function

  # The salon-locale ActiveSupport::TimeZone (Europe/Paris).
  def zone
    @zone ||= Time.find_zone!(ZONE_NAME)
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
  #   2. `zone.iso8601` computes the VALUE, in a zone this file names. A string
  #      WITH an offset is an absolute instant and resolves identically from
  #      every clock; one WITHOUT is read AT THE SALON, because that is where
  #      the chair is — never in the server process's zone.
  #
  # @param raw [Object] the wire value, whatever arrived
  # @return [ActiveSupport::TimeWithZone] the instant, in the salon's zone
  # @raise [ArgumentError, TypeError] on anything that is not an ISO 8601 instant
  def parse_slot(raw)
    str = raw.to_s
    Time.iso8601(str)
    zone.iso8601(str)
  end
end
