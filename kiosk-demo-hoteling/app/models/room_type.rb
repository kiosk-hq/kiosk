# frozen_string_literal: true

# A bookable room category at one property, priced per night in EUR cents. One
# live booking on a room type holds it for those nights.
class RoomType < ApplicationRecord
  belongs_to :property
  has_many :bookings, dependent: :destroy

  # The room types of a property with no live booking on these nights.
  scope :free_for, lambda { |property_id, check_in, check_out|
    where.not(id: Booking.live.where(property_id: property_id)
                              .overlapping(check_in, check_out)
                              .select(:room_type_id))
  }
end
