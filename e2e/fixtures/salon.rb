# frozen_string_literal: true

class Salon < ApplicationRecord
  has_many :appointments, dependent: :restrict_with_exception
end
