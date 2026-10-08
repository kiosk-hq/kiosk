# frozen_string_literal: true

# The clock a listing's publication time is read on: the reader's declared
# `Kiosk-Timezone`, else the board's own.
module BoardClock
  DEFAULT_ZONE_NAME = "Europe/Lisbon"

  module_function

  def default_zone
    @default_zone ||= Time.find_zone!(DEFAULT_ZONE_NAME)
  end

  def zone
    Kiosk::Server::CurrentRequest.timezone || default_zone
  end

  # A String, so the published bytes do not depend on the JSON encoder's
  # time precision.
  def publish(time, in_zone = zone)
    time&.in_time_zone(in_zone)&.iso8601
  end
end
