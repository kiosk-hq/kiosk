# frozen_string_literal: true

class Restaurant < ApplicationRecord
  has_many :table_slots, dependent: :restrict_with_exception
  has_many :bookings,    dependent: :restrict_with_exception
end
