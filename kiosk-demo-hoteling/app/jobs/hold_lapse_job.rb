# frozen_string_literal: true

# A hold's pay-by time has come: cancel it if it is still unpaid.
class HoldLapseJob < ApplicationJob
  queue_as :default

  def perform(booking_id) = Booking.cancel_lapsed!(booking_id)
end
