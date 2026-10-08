# frozen_string_literal: true

# The engine's reserve-then-pay row for a booking, stamped with the time the
# guest is expected to have paid by. Nothing here enforces that deadline.
class RoomHold < ApplicationRecord
  self.table_name = "kiosk.reservations"

  RESOURCE_KIND = "room_booking"
  PAY_BY = 15.minutes
end
