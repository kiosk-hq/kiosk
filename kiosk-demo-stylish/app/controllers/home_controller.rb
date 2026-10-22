# frozen_string_literal: true

# The salon's public page. It advertises the Kiosk skill to an assistant that reads it.
class HomeController < ApplicationController
  include Kiosk::SkillLink

  # An assistant that ranks Markdown first in Accept (q-value, then order) reads the page as Markdown.
  # Rails alone answers HTML to every Accept that also lists */*.
  before_action only: :index do
    response.set_header('Vary', 'Accept')
    request.format = :md if request.accepts.first == Mime[:md]
  end

  def index
    @services            = Service.count
    @appointments_booked = Appointment.count
    @forecast_eur        = Service.format_eur(Appointment.sum(:price_cents))
  end
end
