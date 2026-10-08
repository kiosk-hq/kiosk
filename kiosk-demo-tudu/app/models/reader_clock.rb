# frozen_string_literal: true

# A deadline is stored as an instant and read on the clock of whoever reads it:
# the zone the caller declares in `Kiosk-Timezone`, else the household's own.
module ReaderClock
  DEFAULT_ZONE_NAME = "Europe/Lisbon"

  module_function

  def default_zone = Time.find_zone!(DEFAULT_ZONE_NAME)

  def zone = Kiosk::Server::CurrentRequest.timezone || default_zone

  def publish(time, in_zone = zone) = time&.in_time_zone(in_zone)&.iso8601

  # "Tue 8 Sep, 14:00 (Europe/Istanbul)"
  def label(time, in_zone = zone)
    return if time.nil?

    "#{time.in_time_zone(in_zone).strftime("%a %-d %b, %H:%M")} (#{in_zone.name})"
  end

  # Tomorrow at 14:00 on the household's clock: the deadline `add_todo` offers as an example.
  def example_due_at = default_zone.now.advance(days: 1).change(hour: 14).iso8601
end
