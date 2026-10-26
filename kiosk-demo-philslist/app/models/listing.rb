# frozen_string_literal: true

# A classifieds ad. `price_text` is display text ("€300", "Free" or nil), never
# an amount: the board carries no money.
class Listing < ApplicationRecord
  enum :status, { open: 'open', closed: 'closed' }

  belongs_to :owner, class_name: 'User', inverse_of: :listings
  belongs_to :category

  # The longest title, body and price text the board shows; the post_listing
  # and edit_listing schemas hold the same limits.
  MAX_LENGTH = { title: 120, body: 2000, price_text: 40 }.freeze

  validates :title, :body, presence: true
  MAX_LENGTH.each { |field, maximum| validates field, length: { maximum: } }

  scope :own, -> { where(owner_id: Kiosk.current_user_id) }

  # One answer for absent and foreign, so a foreign id reads as absent.
  def self.own!(id)
    own.find_by(id:) or
      raise Kiosk::Server::Errors::Forbidden.new('listing_id is not one of your listings.',
                                                 hint: 'Pass a listing_id from my_listings.')
  end

  # The public board: the fifty newest open listings, every owner's.
  scope :on_board, -> { open.includes(:category, :owner).order(created_at: :desc, id: :asc).limit(50) }
end
