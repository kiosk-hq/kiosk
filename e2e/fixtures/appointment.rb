# frozen_string_literal: true

class Appointment < ApplicationRecord
  include Kiosk::Owned

  belongs_to :user
  belongs_to :salon
end
