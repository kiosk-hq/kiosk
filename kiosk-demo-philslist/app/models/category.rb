# frozen_string_literal: true

# A classifieds section, referenced in the protocol by slug.
class Category < ApplicationRecord
  has_many :listings, dependent: :restrict_with_exception

  validates :slug, presence: true, uniqueness: true
  validates :name, presence: true
end
