# frozen_string_literal: true

class Appointment < ApplicationRecord
  belongs_to :user
  belongs_to :salon
  # The staff member (users row, staff_role stylist/owner) assigned to this
  # appointment. Optional: legacy customer bookings carry no stylist.
  belongs_to :stylist, class_name: "User", optional: true
  # The service booked from the salon's menu. Optional: legacy bookings that
  # predate the menu carry no service (and no captured price).
  belongs_to :service, optional: true
end
