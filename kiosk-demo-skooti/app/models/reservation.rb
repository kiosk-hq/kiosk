# frozen_string_literal: true

# A hold on one fleet vehicle for one principal. `status` is the ride,
# `payment_status` the money.
class Reservation < ApplicationRecord
  include Kiosk::Owned

  enum :status, { reserved: "reserved", active: "active" }
  enum :payment_status, { unpaid: "unpaid", paying: "paying", paid: "paid" }

  belongs_to :user
  belongs_to :scooter, optional: true

  # The handle a reservation is asked for by; it names the vehicle to hold.
  attribute :scooter_code, :string
  before_validation { self.scooter ||= Scooter.find_by(code: scooter_code) if scooter_code }

  validate :scooter_in_fleet, on: :create
  # Which rental verb activates it depends on the vehicle.
  validate :licence_free,     on: :start_rental
  validate :licence_required, on: :rent_motorcycle

  # A settlement whose cart names this reservation (`line_items @> [{reservation_id}]`).
  SETTLEMENT_FOR_ROW = Arel.sql(
    "kiosk.cart_mandates.line_items @> " \
    "json_build_array(json_build_object('reservation_id', reservations.id::text))::jsonb",
  ).freeze

  # Adds `settled`, read from the given settlements.
  scope :with_settlement, lambda { |settlements|
    settlement = settlements.joins(:cart_mandate).where(SETTLEMENT_FOR_ROW)
    select(arel_table[Arel.star], Arel::Nodes::Exists.new(settlement.select(Arel.sql("1")).arel).as("settled"))
  }

  def self.readable_by?(reservation_id, user_id) = where(id: reservation_id, user_id: user_id).exists?

  def self.announce_payment(reservation_id)
    Kiosk::Server::Events.emit(
      topic: :booking_payment, subject: reservation_id, identity_scope: [find(reservation_id).user_id],
      data: { "reservation_id" => reservation_id, "payment_state" => "paid" },
    )
  end

  # What `my_reservations` publishes about the money. `pending` means a capture
  # is in flight: the caller must reconcile, not sign a new mandate.
  def payment_state
    return "paid"    if paid? || settled
    return "pending" if paying?

    "unpaid"
  end

  private

  def scooter_in_fleet
    return if scooter

    errors.add(:scooter_code, "#{scooter_code} is not in this fleet — call scooters_available for the " \
                              "vehicles you can reserve")
  end

  def licence_free
    return if scooter.licence_free?

    errors.add(:base, "#{scooter.code} is a licence-required motorcycle — use rent_motorcycle for " \
                      "licence-required vehicles; it requires the KYC attributes age_over_18 and " \
                      "licence_a, so POST <endpoint>/request_kyc first if you do not have them yet")
  end

  def licence_required
    return if scooter.licence_required?

    errors.add(:base, "#{scooter.code} is not a licence-required motorcycle — use start_rental for " \
                      "licence-free vehicles")
  end
end
