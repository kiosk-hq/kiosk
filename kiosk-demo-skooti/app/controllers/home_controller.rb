# frozen_string_literal: true

# The public landing page: the fleet, its activity, and the skill.
class HomeController < ApplicationController
  def index
    @scooters_in_fleet    = Scooter.scooter.count
    @motorcycles_in_fleet = Scooter.motorcycle.count
    @vehicles_reserved    = Reservation.count
    @rides_started        = Reservation.active.count

    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end
end
