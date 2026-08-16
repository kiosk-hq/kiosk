# frozen_string_literal: true

# A bookable room category at one property ("Standard", "Suite"), priced per
# night in EUR cents. Inventory is per room TYPE in this demo: one live booking
# on a room type holds it for those nights.
class RoomType < ApplicationRecord
  belongs_to :property
  has_many :bookings, dependent: :destroy

  # THE OFFER `availability` publishes and `reserve_room` sells against: the room
  # types of one property with no live booking overlapping the requested nights.
  # Both verbs — and `hotel_detail`'s dated form — call this one scope, so the
  # three cannot answer differently about the same nights (K-690). The overlap
  # test itself belongs to {Booking.overlapping}.
  #
  # `where.not(id: <relation>)` is a NOT IN over a subquery, which is what the
  # hand-written SELECT did. NOT IN is only safe when the subquery cannot yield
  # NULL, and it cannot: `bookings.room_type_id` is NOT NULL.
  scope :free_for, lambda { |property_id, check_in, check_out|
    where.not(id: Booking.live.where(property_id: property_id)
                              .overlapping(check_in, check_out)
                              .select(:room_type_id))
  }
end
