# frozen_string_literal: true

# The salon's public page. It advertises the Kiosk skill to an assistant that reads it.
class HomeController < ApplicationController
  def index
    @services            = Service.count
    @appointments_booked = Appointment.count
    @forecast_eur        = Service.format_eur(Appointment.sum(:price_cents))

    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end
end
