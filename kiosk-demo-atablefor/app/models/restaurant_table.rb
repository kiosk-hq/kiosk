# frozen_string_literal: true

# A physical table, offered for every upcoming seating.
class RestaurantTable < ApplicationRecord
  belongs_to :restaurant
  has_many   :bookings, dependent: :restrict_with_exception
end
