# frozen_string_literal: true

# The landing page: how to point an assistant here, and the public reservations board.
class HomeController < ApplicationController
  include Kiosk::SkillLink

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
