# frozen_string_literal: true

# The public landing page: what this demo is, live booking counts, and where an
# assistant finds the Kiosk skill.
class HomeController < ApplicationController
  def index
    confirmed        = Booking.confirmed
    @rooms_booked    = confirmed.count
    @nights_reserved = confirmed.sum(Arel.sql("check_out - check_in")).to_i
    @properties      = Property.count
    @room_types      = RoomType.count

    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end
end
