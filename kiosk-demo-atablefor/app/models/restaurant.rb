# frozen_string_literal: true

class Restaurant < ApplicationRecord
  has_many :menu_items, dependent: :restrict_with_exception
  has_many :orders, dependent: :restrict_with_exception
end
