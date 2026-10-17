# frozen_string_literal: true

# A booking's seating has come: a confirmed booking counts as a visit.
class SeatingJob < ApplicationJob
  queue_as :default

  def perform(booking_id) = Booking.honour!(booking_id)
end
