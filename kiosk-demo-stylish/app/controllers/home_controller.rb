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
    # The model is EVERGREEN availability (K-446): the salon's structure is the
    # OPEN slots (7 stylists, one slot each) — always present, never stale —
    # while bookings accumulate as visitors book (starts at 0).
    @open_slots          = StylistSlot.count
    @appointments_booked = Appointment.count
    @stylists            = User.where(staff_role: "stylist").count

    # Forecasted revenue: the day's PROJECTED earnings if the open slots fill,
    # summed from the real slot prices (never hardcoded). What the staff view
    # shows a salon owner. Cents → whole-euro string.
    @forecast_eur = Service.format_eur(StylistSlot.sum(:price_cents))

    # Set a Link header too, so a header-only agent finds the skill.
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end
end
