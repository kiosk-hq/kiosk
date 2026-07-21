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
    @appointments_booked = Appointment.count
    @upcoming            = Appointment.where("slot >= ?", Time.current).count
    @staff_on_book       = User.where.not(staff_role: nil).count
    @salons              = Salon.count

    # Set a Link header too, so a header-only agent finds the skill.
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end
end
