# frozen_string_literal: true
class Store < ApplicationRecord
  has_many :products
  has_many :substitution_policies
  has_many :carts
end
