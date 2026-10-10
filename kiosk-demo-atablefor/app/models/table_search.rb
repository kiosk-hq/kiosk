# frozen_string_literal: true

# The filters of an availability search. Blank filters nothing.
class TableSearch
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :party_size, :integer
  attribute :neighborhood, :string
  attribute :date, :string
  attribute :time, :string

  validate :neighborhood_served, if: -> { neighborhood.present? }
  validate :date_upcoming, if: -> { date.present? }

  # The restaurants in the neighbourhood, each with only its tables that seat the party.
  def restaurants
    scope = Restaurant.includes(:restaurant_tables)
                      .where(restaurant_tables: { capacity: party_size.. })
                      .order(:name, "restaurant_tables.capacity", "restaurant_tables.label")
    neighborhood.present? ? scope.where(neighborhood:) : scope
  end

  # The restaurant's upcoming seatings on the requested date and time.
  def seatings(restaurant)
    restaurant.upcoming_seatings
              .select { |seating| date.blank? || seating.to_date.iso8601 == date }
              .select { |seating| time.blank? || seating.strftime("%H:%M") == time }
  end

  private

  def neighborhood_served
    served = Restaurant.served_neighborhoods
    return if served.include?(neighborhood)

    errors.add(:neighborhood, "#{neighborhood.inspect} is not one this aggregator serves — currently #{listed(served)}")
  end

  def date_upcoming
    dates = Restaurant.select(:timezone).distinct.flat_map(&:upcoming_seatings).map { _1.to_date.iso8601 }.uniq.sort
    return if dates.include?(date)

    errors.add(:date, "#{date.inspect} is not among the upcoming seatings — currently #{listed(dates)}")
  end

  def listed(values) = values.join(", ").presence || "none"
end
