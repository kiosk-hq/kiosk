# frozen_string_literal: true

# The landing page: how to point an assistant here, and the public reservations board.
class HomeController < ApplicationController
  include Kiosk::SkillLink

  # An assistant that ranks Markdown first in Accept (q-value, then order) reads the page as Markdown.
  # Rails alone answers HTML to every Accept that also lists */*.
  before_action only: :index do
    response.set_header('Vary', 'Accept')
    request.format = :md if request.accepts.first == Mime[:md]
  end

  def index
    @tables_booked = Booking.confirmed.count
    @covers_seated = Booking.confirmed.sum(:party_size)
    @restaurants   = Restaurant.count
    @reservations  = Booking.on_board
  end

  def reservations
    @reservations = Booking.on_board
  end
end
