# frozen_string_literal: true

class Property < ApplicationRecord
  has_many :room_types, dependent: :destroy
  has_many :bookings, dependent: :destroy
end
