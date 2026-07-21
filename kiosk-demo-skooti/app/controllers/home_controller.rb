# frozen_string_literal: true

# The provider's public root page. skooti is api_only, but this controller
# inherits from ActionController::Base (not ::API) so it can render an HTML
# landing — the same pattern getgrocery uses. Its job: tell a human/agent
# visitor what this demo is, show live DOMAIN activity (real fleet + rental
# counts), and point at the Kiosk discovery entrypoint + skill.
class HomeController < ActionController::Base
  def index
    # Cheap domain counts, rendered server-side on page load (a refresh is
    # enough — no JS polling). These read skooti's OWN tables, not telemetry.
    @scooters_in_fleet    = Scooter.where(kind: "scooter").count
    @motorcycles_in_fleet = Scooter.where(kind: "motorcycle").count
    @vehicles_reserved    = Reservation.count
    @rides_started        = Reservation.where(status: "active").count

    # Set a Link header too, so a header-only agent finds the skill.
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end
end
