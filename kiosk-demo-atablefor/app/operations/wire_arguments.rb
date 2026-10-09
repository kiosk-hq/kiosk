# frozen_string_literal: true

# Argument checks the verbs' input schemas cannot express. Each raises a 400.
module WireArguments
  # PostgreSQL `integer`: the width of `bookings.party_size` and `restaurant_tables.capacity`.
  MAX_INT4 = 2_147_483_647

  module_function

  # The instant of a seating `availability` is offering at this restaurant now.
  def seating!(date, time, zone)
    refuse "unknown seating time: #{time} — use \"19:00\" | \"20:00\" | \"21:00\"" unless Seatings::TIMES.include?(time)

    day = Date.iso8601(date)
    if Seatings.past?(day, time, zone)
      refuse "seating #{date} #{time} has already started — call availability again for the still-bookable seatings"
    end
    seating_date!(date, Seatings.upcoming(zone: zone))

    Seatings.seating_at(day, time, zone)
  end

  # The rolling horizon changes daily, so no `enum` can name it. Blank filters nothing.
  def seating_date!(date, upcoming)
    dates = upcoming.map { |day, _time| day.iso8601 }.uniq
    return if date.blank? || dates.include?(date)

    refuse "date #{date.inspect} is not among the upcoming seatings — currently #{served_list(dates)}"
  end

  # The served set comes from the restaurants table, so no `enum` can name it. Blank filters nothing.
  def neighborhood!(name, served)
    return if name.blank? || served.include?(name)

    refuse "neighborhood #{name.inspect} is not one this aggregator serves — currently #{served_list(served)}"
  end

  def served_list(values) = values.empty? ? "none" : values.join(", ")

  def refuse(message, hint: nil)
    raise Kiosk::Server::Errors::BadRequest.new(message, hint: hint)
  end
end
