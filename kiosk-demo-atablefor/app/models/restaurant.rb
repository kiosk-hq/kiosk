# frozen_string_literal: true

class Restaurant < ApplicationRecord
  has_many :restaurant_tables, dependent: :restrict_with_exception
  has_many :bookings,          dependent: :restrict_with_exception

  # The clock this restaurant's seatings are on.
  def zone = Time.find_zone!(timezone)

  def self.served_neighborhoods = distinct.order(:neighborhood).pluck(:neighborhood).compact
end
