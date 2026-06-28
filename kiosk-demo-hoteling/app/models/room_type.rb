# frozen_string_literal: true

class RoomType < ApplicationRecord
  belongs_to :property
  has_many :bookings, dependent: :destroy
end
