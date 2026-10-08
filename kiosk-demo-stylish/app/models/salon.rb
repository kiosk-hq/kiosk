# frozen_string_literal: true

class Salon < ApplicationRecord
  has_many :appointments, dependent: :restrict_with_exception

  def zone = Time.find_zone!(timezone)
end
