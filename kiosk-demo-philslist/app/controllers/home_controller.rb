# frozen_string_literal: true

# The public root page and the read-only board.
class HomeController < ApplicationController
  include Kiosk::SkillLink

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
