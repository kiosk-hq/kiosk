# frozen_string_literal: true

# One hotel, sold on its own clock (`timezone`).
class Property < ApplicationRecord
  # The closed vocabularies behind the search_hotels enums and the seeds. A
  # constant, not a query over properties: an unserved district is a 400, not [].
  AMENITIES = %w[wifi breakfast pool spa gym parking rooftop_bar
                 airport_shuttle sea_view pet_friendly restaurant hammam].freeze
  NEIGHBOURHOODS = %w[Sultanahmet Beyoğlu Kadıköy Beşiktaş Şişli Fatih
                      Üsküdar Galata Taksim Ortaköy Bakırköy Nişantaşı].freeze

  has_many :room_types, dependent: :destroy
  has_many :bookings, dependent: :destroy

  def zone = Time.find_zone!(timezone)

  # The cheapest nightly rate this property offers, in EUR cents.
  def self.from_price_cents
    rt = RoomType.arel_table
    Arel::Nodes::Grouping.new(
      rt.project(rt[:nightly_price_cents].minimum).where(rt[:property_id].eq(arel_table[:id])).ast
    )
  end

  def self.room_type_count
    rt = RoomType.arel_table
    Arel::Nodes::Grouping.new(
      rt.project(Arel.star.count).where(rt[:property_id].eq(arel_table[:id])).ast
    )
  end

  # `amenities @> '["spa"]'`
  scope :offering, lambda { |amenity|
    where(Arel::Nodes::InfixOperation.new(
            '@>', arel_table[:amenities], Arel::Nodes.build_quoted([amenity].to_json)
          ))
  }
end
