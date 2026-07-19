# frozen_string_literal: true

# A classifieds section (furniture, bikes, electronics, housing, free). Seeded
# by db/seeds.rb; referenced by slug in browse_listings / post_listing.
class Category < ApplicationRecord
  has_many :listings, dependent: :restrict_with_exception

  validates :slug, presence: true, uniqueness: true
  validates :name, presence: true
end
