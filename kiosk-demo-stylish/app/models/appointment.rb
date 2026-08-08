# frozen_string_literal: true

class Appointment < ApplicationRecord
  belongs_to :user
  belongs_to :salon
  # The service booked from the salon's menu. Optional: legacy bookings that
  # predate the menu (or a bare salon_id booking) carry no service and no
  # captured price. The captured price_cents drives the owner's forecast.
  belongs_to :service, optional: true
end
