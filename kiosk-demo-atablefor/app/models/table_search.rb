# frozen_string_literal: true

# The filters of an availability search. Blank filters nothing.
class TableSearch
  # The days a search with no date shows: today and tomorrow.
  UNDATED_DAYS = 2

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
                      .order(:name, 'restaurant_tables.capacity', 'restaurant_tables.label')
    neighborhood.present? ? scope.where(neighborhood:) : scope
  end

  # `[restaurant, table, seating]` for every table that seats the party and is not booked for the seating.
  def open_tables
    found = restaurants.to_a
    taken = Booking.confirmed.where(restaurant: found, seating_at: Time.current..)
                   .pluck(:restaurant_table_id, :seating_at).to_set

    found.flat_map { |restaurant| open_at(restaurant, taken) }
  end

  # `[restaurant, table, seating]` for each of the restaurant's tables not in `taken` at a seating.
  def open_at(restaurant, taken)
    restaurant.restaurant_tables.to_a.product(seatings(restaurant))
              .reject { |table, seating| taken.include?([table.id, seating]) }
              .map { |table, seating| [restaurant, table, seating] }
  end

  # The restaurant's upcoming seatings on the requested date and time.
  def seatings(restaurant)
    restaurant.upcoming_seatings(days: date.blank? ? UNDATED_DAYS : Restaurant::BOOKING_DAYS)
              .select { |seating| date.blank? || seating.to_date.iso8601 == date }
              .select { |seating| time.blank? || seating.strftime('%H:%M') == time }
  end

  private

  def neighborhood_served
    served = Restaurant.served_neighborhoods
    return if served.include?(neighborhood)

    errors.add(:neighborhood, "#{neighborhood.inspect} is not served; try one of #{listed(served)}")
  end

  def date_upcoming
    dates = Restaurant.select(:timezone).distinct.flat_map(&:upcoming_seatings).map { it.to_date.iso8601 }.uniq.sort
    return if dates.include?(date)

    errors.add(:date, "#{date.inspect} has no upcoming seatings; pick a date from #{dates.first} to #{dates.last}")
  end

  def listed(values) = values.join(', ').presence || 'none'
end
