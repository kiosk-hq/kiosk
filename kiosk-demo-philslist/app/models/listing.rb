# frozen_string_literal: true

# A classifieds ad. `price_text` is display text ("€300", "Free" or nil), never
# an amount: the board carries no money.
class Listing < ApplicationRecord
  enum :status, { open: "open", closed: "closed" }

  belongs_to :owner, class_name: "User", inverse_of: :listings
  belongs_to :category

  validates :title, :body, presence: true

  scope :own, -> { where(owner_id: Kiosk.current_user_id) }

  # The public board: the fifty newest open listings, every owner's.
  scope :on_board, -> { open.includes(:category, :owner).order(created_at: :desc, id: :asc).limit(50) }
end
