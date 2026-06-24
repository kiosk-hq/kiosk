# frozen_string_literal: true

class Scooter < ApplicationRecord
  has_many :reservations, dependent: :destroy
end
