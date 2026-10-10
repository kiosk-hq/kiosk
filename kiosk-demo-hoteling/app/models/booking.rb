# frozen_string_literal: true

# A hold on one room type for a run of nights. `status` is the room-night,
# `payment_status` is the money; the property answers a paid booking by
# confirming or cancelling it.
class Booking < ApplicationRecord
  include Kiosk::Owned

  MAX_NIGHTS = 30

  enum :status, {
    reserved:  "reserved",
    confirmed: "confirmed",
    cancelled: "cancelled",
  }

  enum :payment_status, {
    unpaid:   "unpaid",
    paying:   "paying",
    paid:     "paid",
    refunded: "refunded",
  }

  belongs_to :user
  belongs_to :property
  belongs_to :room_type

  validates_with StayValidator, on: :create
  validate :stay_length, :room_type_at_property, on: :create

  # The bookings that hold their nights; `bookings_no_overlapping_room_nights`
  # is scoped the same way.
  scope :live, -> { where(status: %i[reserved confirmed]) }

  # Half-open nights: a checkout day is the next guest's check-in day.
  scope :overlapping, lambda { |check_in, check_out|
    where(arel_table[:check_in].lt(check_out)).where(arel_table[:check_out].gt(check_in))
  }

  # A settlement whose cart names this booking (`line_items @> [{booking_id}]`).
  SETTLEMENT_FOR_ROW = Arel.sql(
    "kiosk.cart_mandates.line_items @> json_build_array(json_build_object('booking_id', bookings.id::text))::jsonb",
  ).freeze

  # Adds `settled`, read from the given settlements.
  scope :with_settlement, lambda { |settlements|
    settlement = settlements.joins(:cart_mandate).where(SETTLEMENT_FOR_ROW)
    select(arel_table[Arel.star],
           Arel::Nodes::Exists.new(settlement.select(Arel.sql("1")).arel).as("settled"))
  }

  def self.readable_by?(booking_id, user_id) = where(id: booking_id, user_id: user_id).exists?

  # The capture returned: tell the owner, and let the property decide. A zero
  # wait decides inline.
  def self.captured!(booking_id)
    owner_id = where(id: booking_id).pick(:user_id)
    if owner_id
      Kiosk::Server::Events.emit(
        topic: :booking_payment, subject: booking_id, identity_scope: [owner_id],
        data: { "booking_id" => booking_id, "payment_state" => "paid" },
      )
    end
    wait = Rails.configuration.x.hoteling.decision_delay_seconds.to_i
    where(id: booking_id).update_all(decision_due_at: Time.current + wait)
    return PropertyDecisionJob.new.perform(booking_id) if wait.zero?

    PropertyDecisionJob.set(wait: wait.seconds).perform_later(booking_id)
  end

  def nights = (check_out - check_in).to_i

  # What `my_bookings` publishes about the money. `pending` means a capture is
  # in flight: the caller must reconcile, not sign a new mandate.
  def payment_state
    return "refunded" if refunded?
    return "paid"     if paid? || settled
    return "pending"  if paying?

    "unpaid"
  end

  private

  def stay_length
    return if check_in.nil? || check_out.nil? || nights <= MAX_NIGHTS

    errors.add(:check_out, "is #{nights} nights after check_in; one reservation holds at most #{MAX_NIGHTS}")
  end

  def room_type_at_property
    return if room_type.nil? || room_type.property_id == property_id

    errors.add(:room_type, "#{room_type_id} is not a room type of property #{property_id} — call availability " \
                           "for the ones it has")
  end
end
