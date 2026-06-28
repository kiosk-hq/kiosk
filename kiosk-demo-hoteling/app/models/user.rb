# frozen_string_literal: true

class User < ApplicationRecord
  has_many :bookings, dependent: :destroy
end
