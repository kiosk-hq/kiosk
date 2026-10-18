# frozen_string_literal: true

# A hold on one room type for a run of nights. `status` is the room-night,
# `payment_status` is the money; the property answers a paid booking by
# confirming or cancelling it.
class Booking < ApplicationRecord
  include Kiosk::Owned
  include Kiosk::Payable

  MAX_NIGHTS = 30
  # An unpaid hold lapses this long after `reserve_room`, and its nights are free again.
  PAY_WINDOW = 15.minutes

  enum :status, {
    reserved: 'reserved',
    confirmed: 'confirmed',
    cancelled: 'cancelled'
  }

  enum :payment_status, {
    unpaid: 'unpaid',
    paying: 'paying',
    paid: 'paid',
    refunded: 'refunded'
  }

  belongs_to :user
  belongs_to :property, optional: true
  belongs_to :room_type

  before_validation(on: :create) { self.property = room_type&.property }
  validates_with StayValidator, on: :create
  validate :stay_length, on: :create

  scope :lapsed, -> { unpaid.where(created_at: ..PAY_WINDOW.ago) }

  # The bookings that hold their nights. `bookings_no_overlapping_room_nights`
  # still counts a lapsed hold until `cancel_lapsed!` cancels it.
  scope :live, -> { where(status: %i[reserved confirmed]).where.not(id: lapsed.select(:id)) }

  # Half-open nights: a checkout day is the next guest's check-in day.
  scope :overlapping, lambda { |check_in, check_out|
    where(arel_table[:check_in].lt(check_out)).where(arel_table[:check_out].gt(check_in))
  }

  def self.readable_by?(booking_id, user_id) = exists?(id: booking_id, user_id: user_id)

  # The capture returned: let the property decide. A zero wait decides inline.
  def self.captured!(booking_id)
    wait = Rails.configuration.x.hoteling.decision_delay_seconds.to_i
    find(booking_id).update!(decision_due_at: wait.seconds.from_now)
    return PropertyDecisionJob.new.perform(booking_id) if wait.zero?

    PropertyDecisionJob.set(wait: wait.seconds).perform_later(booking_id)
  end

  # Cancels a hold left unpaid past its pay-by time and tells its owner, once:
  # the row lock makes two calls take turns, and the second finds no lapsed hold.
  def self.cancel_lapsed!(booking_id)
    transaction do
      booking = reserved.lapsed.lock.find_by(id: booking_id)
      next unless booking

      booking.cancelled!
      Kiosk::Server::Events.emit(
        topic: :booking_confirmation, subject: booking.id, identity_scope: [booking.user_id],
        data: { 'booking_id' => booking.id, 'status' => 'cancelled', 'reason' => 'hold_lapsed' }
      )
    end
  end

  def nights = (check_out - check_in).to_i

  def pay_by = created_at + PAY_WINDOW

  def lapsed? = unpaid? && pay_by.past?

  # What `my_bookings` publishes about the stay: a lapsed hold reads cancelled.
  def stay_status = lapsed? ? 'cancelled' : status

  private

  def stay_length
    return if check_in.nil? || check_out.nil? || nights <= MAX_NIGHTS

    errors.add(:check_out, "is #{nights} nights after check_in; one reservation holds at most #{MAX_NIGHTS}")
  end
end
