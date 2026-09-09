# frozen_string_literal: true

# ── The clock a listing's publication time is READ on ───────────────────────
#
# philslist has no service address: a classified ad is not delivered anywhere,
# and «when was this posted» is a question the READER asks about their own day
# -- "this morning", "three days ago". So the publication instant is rendered
# in the zone the CALLER declares in `Kiosk-Timezone`, and the row says which
# zone that was.
#
# WHEN THE CALLER DECLARES NOTHING, this board's own clock answers and the row
# SAYS SO. That is a declared default, not a guess, and it is the only place a
# constant appears here.
#
# WHY A CONSTANT AND NOT A COLUMN, which is the opposite of what the demos with
# an address do: there, the zone belongs to a RESOURCE, because the service
# happens at a place that resource names. Here it is the reader's own, and a
# reader is not a row in this database -- there is nothing to put a column on.
module BoardClock
  # The board's own clock -- the DECLARED fallback for a caller that declares
  # none. A real IANA zone, so DST is handled; do NOT replace it with a fixed
  # offset.
  DEFAULT_ZONE_NAME = "Europe/Lisbon"

  module_function

  def default_zone
    @default_zone ||= Time.find_zone!(DEFAULT_ZONE_NAME)
  end

  # The zone THIS request is answered on: the caller's declared one, or the
  # board's when it declared none.
  def zone
    Kiosk::Server::CurrentRequest.timezone || default_zone
  end

  # An instant as this demo PUBLISHES it, on the reader's clock, as a String.
  #
  # A String and not a Time: an `ActiveSupport::TimeWithZone` renders through
  # `Time.zone` and the JSON encoder's `time_precision`, so the published bytes
  # would be the app's configuration talking rather than this file.
  def publish(time, in_zone = zone)
    time&.in_time_zone(in_zone)&.iso8601
  end
end
