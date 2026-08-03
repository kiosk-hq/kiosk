# frozen_string_literal: true

# A classifieds ad. The load-bearing detail: `price_text` is a plain NULLABLE
# STRING ("€300", "Free", or NULL), NOT a money type — the board never
# transacts on it. A commerce reviewer looking for a hidden PSP finds only a
# display string. `owner_id` is the account that posted the ad; `edit`/`close`
# are scoped to `owner_id = kiosk.current_user_id()` (app-layer isolation).
class Listing < ApplicationRecord
  STATUSES = %w[open closed].freeze

  belongs_to :owner, class_name: "User", foreign_key: :owner_id, inverse_of: :listings
  belongs_to :category

  validates :title, presence: true
  validates :body, presence: true
  validates :status, inclusion: { in: STATUSES }
end
