# frozen_string_literal: true

# Releases every paid hold whose ride did not start within Reservation::HOLD
# and refunds its payment (config/recurring.yml runs it).
class RefundUnstartedJob < ApplicationJob
  queue_as :default

  def perform
    Reservation.unstarted.ids.each { Reservation.refund_unstarted!(it) }
  end
end
