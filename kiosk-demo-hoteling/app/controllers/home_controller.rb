# frozen_string_literal: true

# The provider's public root page. It inherits from ApplicationController
# (ActionController::Base, not ::API — the app carries the full middleware
# stack for the Devise human sessions) so it can render an HTML landing, and
# so an assistant that JSON-POSTs at a human page gets the K-459 signpost. Its
# job: tell a human/agent
# visitor what this demo is, show live DOMAIN activity (real booking counts),
# and point at the Kiosk discovery entrypoint + skill.
class HomeController < ApplicationController
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
    # The url is `Kiosk.configuration.skill_url` — the VERSIONED cut this
    # operator pins, identical to the one `/.well-known/kiosk.json` carries
    # under `skill`, never the mutable skill.md alias (K-927). Derived rather
    # than restated so a cut is re-pinned in ONE place, the initializer.
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end
end
