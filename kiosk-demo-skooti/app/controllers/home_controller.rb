# frozen_string_literal: true

# The public landing page: the fleet, its activity, and the skill.
class HomeController < ApplicationController
  include Kiosk::SkillLink

  # An assistant that ranks Markdown first in Accept (q-value, then order) reads the page as Markdown.
  # Rails alone answers HTML to every Accept that also lists */*.
  before_action only: :index do
    response.set_header('Vary', 'Accept')
    request.format = :md if request.accepts.first == Mime[:md]
  end

  def index
    @scooters_in_fleet    = Scooter.scooter.count
    @motorcycles_in_fleet = Scooter.motorcycle.count
    @vehicles_reserved    = Reservation.count
    @rides_started        = Reservation.active.count
  end
end
