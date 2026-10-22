# frozen_string_literal: true

# The public landing page: what this demo is, live booking counts, and where an
# assistant finds the Kiosk skill.
class HomeController < ApplicationController
  include Kiosk::SkillLink

  # An assistant that ranks Markdown first in Accept (q-value, then order) reads the page as Markdown.
  # Rails alone answers HTML to every Accept that also lists */*.
  before_action only: :index do
    response.set_header('Vary', 'Accept')
    request.format = :md if request.accepts.first == Mime[:md]
  end

  def index
    confirmed        = Booking.confirmed
    @rooms_booked    = confirmed.count
    @nights_reserved = confirmed.sum(Arel.sql('check_out - check_in')).to_i
    @properties      = Property.count
    @room_types      = RoomType.count
  end
end
