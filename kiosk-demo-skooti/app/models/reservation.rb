# frozen_string_literal: true

# A hold on one fleet vehicle for one customer, until `held_until`; the
# database lets one live hold per vehicle. `status` is the ride,
# `payment_status` the money.
class Reservation < ApplicationRecord
  include Kiosk::Owned
  include Kiosk::Payable

  # Time to pay and start the rental; starting it holds the vehicle until the rental token expires.
  # A paid hold whose ride has not started by then is refunded (RefundUnstartedJob).
  HOLD = 3.minutes

  enum :status, { reserved: 'reserved', active: 'active' }
  enum :payment_status, { unpaid: 'unpaid', paying: 'paying', paid: 'paid', refunded: 'refunded' }

  belongs_to :user
  belongs_to :scooter, optional: true

  # The handle a reservation is asked for by; it names the vehicle to hold.
  attribute :scooter_code, :string
  before_validation { self.scooter ||= Scooter.find_by(code: scooter_code) if scooter_code }
  before_create { self.held_until = HOLD.from_now }

  scope :live, -> { where(arel_table[:held_until].gt(Time.current)) }
  # Paid holds whose ride never started.
  scope :unstarted, -> { reserved.paid.where(arel_table[:held_until].lteq(Time.current)) }

  validate :scooter_in_fleet, on: :create
  # Which rental verb activates it depends on the vehicle.
  validate :licence_free,     on: :start_rental
  validate :licence_required, on: :rent_motorcycle

  # Returns the payment of an unstarted hold to the card, once: the row stays
  # locked until it reads `refunded`.
  def self.refund_unstarted!(reservation_id)
    transaction do
      reservation = unstarted.lock.find_by(id: reservation_id)
      charge = reservation&.settlement
      next unless charge

      claim = Kiosk.configuration.payment_provider
      claim.refund(psp_reference: charge.psp_reference, amount_cents: charge.settled_amount_cents, key: reservation.id)
      reservation.refunded!
      claim.announce(reservation.id, 'refunded')
    end
  end

  private

  def scooter_in_fleet
    return if scooter

    errors.add(:scooter_code, "#{scooter_code} is not in this fleet — pick a code from scooters_available")
  end

  def licence_free
    return unless scooter.needs_licence?

    errors.add(:base, "#{scooter.code} needs a licence — rent it with rent_motorcycle")
  end

  def licence_required
    return if scooter.needs_licence?

    errors.add(:base, "#{scooter.code} needs no licence — rent it with start_rental")
  end
end
