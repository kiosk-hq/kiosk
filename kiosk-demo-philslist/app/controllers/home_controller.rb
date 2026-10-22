# frozen_string_literal: true

# The public root page and the read-only board.
class HomeController < ApplicationController
  include Kiosk::SkillLink

  # An assistant that ranks Markdown first in Accept (q-value, then order) reads the page as Markdown.
  # Rails alone answers HTML to every Accept that also lists */*.
  before_action only: :index do
    response.set_header('Vary', 'Accept')
    request.format = :md if request.accepts.first == Mime[:md]
  end

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
