# frozen_string_literal: true

# The provider's public root page. atablefor is api_only=false, and this
# controller inherits from ActionController::Base (not ::API) so it can render an
# HTML landing. Its job: make it OBVIOUS this is a Kiosk endpoint an AI assistant
# drives (the "point your assistant here / this speaks Kiosk" cue + the one-line
# prompt), NOT a human web-booking app — and show the PUBLIC, read-only
# reservations board so a viewer SEES an assistant's booking tied to its diner.
class HomeController < ActionController::Base
  # The home page (protocol-primary framing) + the reservations board rendered
  # inline. Reading the OWN tables; a refresh is enough.
  def index
    @tables_booked  = Booking.confirmed.count
    @covers_seated  = Booking.confirmed.sum(:party_size)
    @restaurants    = Restaurant.count
    @reservations   = Booking.on_board

    # Set a Link header too, so a header-only agent finds the skill.
    # The url is `Kiosk.configuration.skill_url` — the VERSIONED cut this
    # operator pins, identical to the one `/.well-known/kiosk.json` carries
    # under `skill`, never the mutable skill.md alias. Derived rather than
    # restated so a cut is re-pinned in ONE place, the initializer.
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end

  # The board on its own URL. Same data; a standalone read-only page a viewer
  # can bookmark to watch reservations land under each diner's name.
  def reservations
    @reservations = Booking.on_board
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end
end
