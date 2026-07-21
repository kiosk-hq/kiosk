# frozen_string_literal: true

# The provider's public root page. atablefor is api_only, but this controller
# inherits from ActionController::Base (not ::API) so it can render an HTML
# landing — the same pattern getgrocery uses. Its job: tell a human/agent
# visitor what this demo is, show live DOMAIN activity (real booking counts),
# and point at the Kiosk discovery entrypoint + skill.
class HomeController < ActionController::Base
  def index
    # Cheap domain counts, rendered server-side on page load (a refresh is
    # enough — no JS polling). These read atablefor's OWN tables, not telemetry.
    @tables_booked  = Booking.where(status: "confirmed").count
    @covers_seated  = Booking.where(status: "confirmed").sum(:party_size)
    @cancellations  = Booking.where(status: "cancelled").count
    @open_slots     = TableSlot.where(status: "open").count

    # Set a Link header too, so a header-only agent finds the skill.
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end
end
