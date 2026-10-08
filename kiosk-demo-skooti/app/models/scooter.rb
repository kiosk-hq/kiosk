# frozen_string_literal: true

# A fleet vehicle. A `needs_licence` vehicle is rented with `rent_motorcycle`,
# which requires the rider's `age_over_18` and `licence_a`; any other with
# `start_rental`.
class Scooter < ApplicationRecord
  enum :status, { available: "available" }
  enum :kind, { scooter: "scooter", motorcycle: "motorcycle" }

  has_many :reservations, dependent: :destroy

  # Fail-closed in both directions: a flag that does not cast to a literal
  # boolean opens neither rental verb.
  def licence_free?     = licence_flag == false
  def licence_required? = licence_flag == true

  private

  def licence_flag = ActiveRecord::Type::Boolean.new.cast(needs_licence)
end
