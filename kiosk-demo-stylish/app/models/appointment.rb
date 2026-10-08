# frozen_string_literal: true

class Appointment < ApplicationRecord
  include Kiosk::Owned

  belongs_to :user
  belongs_to :salon
  # A bare salon booking names no service and captures no price.
  belongs_to :service, optional: true
end
