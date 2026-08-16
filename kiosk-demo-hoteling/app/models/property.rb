# frozen_string_literal: true

# One hotel. `amenities` is jsonb (a closed vocabulary — AMENITY_POOL in
# config/initializers/kiosk.rb, shared with the seeds and with search_hotels'
# `amenity` enum); `neighbourhood`, `stars` and `address` are the columns
# search_hotels filters on.
#
# The two class methods below are the SUMMARY columns a search_hotels row
# carries. They are correlated scalar subqueries rather than a GROUP BY join
# because that is what the SELECT they replace was, and because each is needed
# in three places at once — the projection, a filter (`max_price_cents`) and the
# ORDER BY — where a join's alias could not be reused. Writing them here rather
# than in the handler keeps the handler free of SQL and means "the cheapest room
# at this property" has ONE definition; nothing caller-supplied appears in
# either, so neither is an injection surface.
class Property < ApplicationRecord
  has_many :room_types, dependent: :destroy
  has_many :bookings, dependent: :destroy

  # The cheapest nightly rate this property offers, in EUR cents.
  def self.from_price_cents
    rt = RoomType.arel_table
    Arel::Nodes::Grouping.new(
      rt.project(rt[:nightly_price_cents].minimum)
        .where(rt[:property_id].eq(arel_table[:id])).ast,
    )
  end

  # How many room types this property lists.
  def self.room_type_count
    rt = RoomType.arel_table
    Arel::Nodes::Grouping.new(
      rt.project(Arel.star.count)
        .where(rt[:property_id].eq(arel_table[:id])).ast,
    )
  end

  # jsonb containment: does this property offer the named amenity? The value is
  # caller-supplied, so it is a QUOTED node (the adapter escapes it) rather than
  # an interpolated fragment — `amenities @> '["spa"]'`. Postgres resolves the
  # untyped literal to jsonb from the left operand, so the explicit `::jsonb`
  # cast the hand-written SQL carried is not needed.
  scope :offering, lambda { |amenity|
    where(Arel::Nodes::InfixOperation.new(
      "@>", arel_table[:amenities], Arel::Nodes.build_quoted([amenity].to_json),
    ))
  }
end
