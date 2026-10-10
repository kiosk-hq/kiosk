# frozen_string_literal: true

# Argument checks the verbs' input schemas cannot express. Each raises.
module WireArguments
  # PostgreSQL `integer`: the width of `bookings.total_cents` and of the
  # columns `search_hotels` filters compare against.
  MAX_INT4 = 2_147_483_647

  # What `properties.timezone` defaults to, and the clock a published example
  # is dated on.
  DEFAULT_ZONE_NAME = "Europe/Istanbul"

  module_function

  def default_zone = Time.find_zone!(DEFAULT_ZONE_NAME)

  # The clock this property is sold on; the default for an id nobody has.
  def zone_for(property_id)
    Property.where(id: property_id).pick(:timezone)&.then { Time.find_zone!(_1) } || default_zone
  end


  # @return [Array(Date, Date)] the first night and the checkout day
  def stay(check_in, check_out)
    first, last = Date.iso8601(check_in), Date.iso8601(check_out)
    refuse "check_out must be after check_in" unless last > first

    [first, last]
  end

  # A room-night before today on the property's clock. Today is bookable.
  def bookable!(check_in, zone:)
    floor = zone.today
    return if check_in >= floor

    refuse "check_in #{check_in.iso8601} is in the past — this hotel sells room-nights from " \
           "#{floor.iso8601} onwards (#{zone.name})",
           hint: "pass #{floor.iso8601} or a later check_in; today IS bookable (a same-day arrival " \
                 "is an ordinary room-night). The date is judged on the PROPERTY's clock, which is " \
                 "not necessarily yours. An EMPTY availability list means the hotel is sold out for " \
                 "those nights, which is a different answer from this one."
  end

  def existing_property!(property_id)
    property_not_found!(property_id) unless Property.exists?(id: property_id)
  end

  def property_not_found!(property_id)
    raise Kiosk::Server::Errors::NotFound.new(
      "hotel not found: #{property_id}",
      hint: "call search_hotels (or properties) and pass a `property_id` from a row.",
    )
  end

  # A stay whose total does not fit `bookings.total_cents`.
  def priceable_total!(total_cents, nights)
    return if total_cents <= MAX_INT4

    refuse "a #{nights}-night stay totals #{total_cents} cents, more than this operator can " \
           "book in one reservation (max #{MAX_INT4})",
           hint: "book a shorter stay — check_in and check_out are the first night and the " \
                 "checkout day, so their distance is the number of nights charged."
  end

  def refuse(message, hint: nil)
    raise Kiosk::Server::Errors::BadRequest.new(message, hint: hint)
  end
end
