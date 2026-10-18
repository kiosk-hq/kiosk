# frozen_string_literal: true

# The public landing page: the fleet, its activity, and the skill.
class HomeController < ApplicationController
  include Kiosk::SkillLink

  def index
    @scooters_in_fleet    = Scooter.scooter.count
    @motorcycles_in_fleet = Scooter.motorcycle.count
    @vehicles_reserved    = Reservation.count
    @rides_started        = Reservation.active.count
  end
end
