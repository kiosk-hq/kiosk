# frozen_string_literal: true

class Appointment < ApplicationRecord
  include Kiosk::Owned

  belongs_to :user
  belongs_to :salon
  # The service booked from the salon's menu. Optional: a bare salon booking
  # names no service and captures no price. The captured price_cents drives the
  # owner's forecast.
  belongs_to :service, optional: true
end
