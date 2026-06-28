# frozen_string_literal: true
class Delivery < ApplicationRecord
  belongs_to :user
  belongs_to :cart
end
