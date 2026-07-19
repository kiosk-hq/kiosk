# frozen_string_literal: true

class Appointment < ApplicationRecord
  belongs_to :user
  belongs_to :salon
  # The staff member (users row, staff_role stylist/owner) assigned to this
  # appointment. Optional: legacy customer bookings carry no stylist.
  belongs_to :stylist, class_name: "User", optional: true
end
