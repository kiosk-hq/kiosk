# frozen_string_literal: true

# Every wall-clock answer is on the clock of the salon it is about
# (`salons.timezone`). `Europe/Paris` is the origin default: what fills that
# column, and what dates a published example, which addresses no salon.
module SalonClock
  DEFAULT_ZONE_NAME = "Europe/Paris"

  module_function

  def default_zone = Time.find_zone!(DEFAULT_ZONE_NAME)

  # An instant as this demo publishes it: on the salon's clock, as a String, so
  # the bytes do not depend on `Time.zone` or the JSON encoder's precision.
  def publish(time, zone = default_zone) = time.in_time_zone(zone).iso8601
end
