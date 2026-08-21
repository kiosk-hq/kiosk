# frozen_string_literal: true

# The provider's public root page (replaces the former inline proc root).
# Devise needs a post-sign-in destination, and a human/agent landing here
# should learn what this demo is, see live DOMAIN activity (real appointment
# counts), and find both doors: the human sign-in and the Kiosk wire.
class HomeController < ApplicationController
  # Self-contained full-HTML page; the app ships no application layout.
  layout false

  def index
    # Cheap domain counts, rendered server-side on page load (a refresh is
    # enough — no JS polling). These read stylish's OWN tables, not telemetry.
    # The model is an EVERGREEN service MENU (K-446): every service is always
    # bookable (infinite capacity, overbooking allowed — the salon never fills
    # up), while bookings accumulate as visitors book (starts at 0).
    @services            = Service.count
    @appointments_booked = Appointment.count

    # Forecasted revenue: the € total SUMMED from the actual bookings' captured
    # prices (never hardcoded). What the staff view shows a salon owner — it
    # starts at €0 and grows with each booking. Cents → EUR string.
    @forecast_eur = Service.format_eur(Appointment.sum(:price_cents))

    # Set a Link header too, so a header-only agent finds the skill.
    # The url is `Kiosk.configuration.skill_url` — the VERSIONED cut this
    # operator pins, identical to the one `/.well-known/kiosk.json` carries
    # under `skill`, never the mutable skill.md alias (K-927). Derived rather
    # than restated so a cut is re-pinned in ONE place, the initializer.
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end
end
