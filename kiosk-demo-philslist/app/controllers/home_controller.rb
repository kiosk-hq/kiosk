# frozen_string_literal: true

# The public root page and the read-only board.
class HomeController < ApplicationController
  before_action { response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk")) }

  def index
    @listings_posted = Listing.count
    @open_listings   = Listing.open.count
    @closed_listings = Listing.closed.count
    @categories      = Category.count
    @board_listings  = Listing.on_board
  end

  def listings
    @board_listings = Listing.on_board
  end
end
