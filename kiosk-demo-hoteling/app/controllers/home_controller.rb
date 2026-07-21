# frozen_string_literal: true

# The provider's public root page. hoteling is api_only, but this controller
# inherits from ActionController::Base (not ::API) so it can render an HTML
# landing — the same pattern getgrocery uses. Its job: tell a human/agent
# visitor what this demo is, show live DOMAIN activity (real booking counts),
# and point at the Kiosk discovery entrypoint + skill.
class HomeController < ActionController::Base
  def index
    # Cheap domain counts, rendered server-side on page load (a refresh is
    # enough — no JS polling). These read hoteling's OWN tables, not telemetry.
    @rooms_booked   = Booking.where(status: "confirmed").count
    # Nights reserved: Postgres date subtraction yields integer days per stay.
    @nights_reserved = Booking.where(status: "confirmed")
                              .sum(Arel.sql("check_out - check_in")).to_i
    @properties     = Property.count
    @room_types     = RoomType.count

    # Set a Link header too, so a header-only agent finds the skill.
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end
end
