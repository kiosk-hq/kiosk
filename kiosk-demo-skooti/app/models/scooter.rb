# frozen_string_literal: true

# A fleet vehicle. One that names a `licence_category` is rented with
# `rent_motorcycle`, which requires the rider's `age_over_18` and the licence
# attribute of that category; one that names none with `start_rental`.
class Scooter < ApplicationRecord
  LICENCE_CATEGORIES = %w[A1 A].freeze

  enum :kind, { scooter: 'scooter', motorcycle: 'motorcycle' }

  has_many :reservations, dependent: :destroy

  validates :licence_category, inclusion: { in: LICENCE_CATEGORIES }, allow_nil: true

  # The vehicles no live reservation holds.
  scope :available, -> { where.not(id: Reservation.live.select(:scooter_id)) }

  def needs_licence? = licence_category.present?

  # The attributes the rider must hold: `licence_a1` for an A1 vehicle.
  def kyc_claims = ['age_over_18', "licence_#{licence_category.downcase}"]
end
