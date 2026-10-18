# frozen_string_literal: true

# The public landing page: what this demo is, live booking counts, and where an
# assistant finds the Kiosk skill.
class HomeController < ApplicationController
  include Kiosk::SkillLink

  def index
    confirmed        = Booking.confirmed
    @rooms_booked    = confirmed.count
    @nights_reserved = confirmed.sum(Arel.sql('check_out - check_in')).to_i
    @properties      = Property.count
    @room_types      = RoomType.count
  end
end
