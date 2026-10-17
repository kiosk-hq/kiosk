# frozen_string_literal: true

# Holds one room type for one stay for the customer until `Booking::PAY_WINDOW`
# passes unpaid, when HoldLapseJob cancels it. Returns the booking; raises a
# wire error on a refusal.
class ReserveRoomOperation
  def self.call(customer_id:, room_type_id:, check_in:, check_out:)
    booking = priced(Booking.new(user_id: customer_id, room_type: RoomType.find_by(id: room_type_id),
                                 check_in: Date.iso8601(check_in), check_out: Date.iso8601(check_out)))
    save_unless_booked!(booking)
    HoldLapseJob.set(wait_until: booking.pay_by).perform_later(booking.id)
    booking
  end

  def self.priced(booking)
    booking.validate!
    booking.total_cents = booking.nights * booking.room_type.nightly_price_cents
    booking
  end

  # The exclusion constraint answers the race the overlap check loses.
  def self.save_unless_booked!(booking)
    already_booked!(booking) if release_lapsed(booking).live.exists?

    booking.save!
  rescue ActiveRecord::ExclusionViolation
    already_booked!(booking)
  end

  # Cancels the lapsed holds on these nights, which the exclusion constraint
  # still counts. Returns the bookings on these nights.
  def self.release_lapsed(booking)
    held = Booking.where(room_type_id: booking.room_type_id).overlapping(booking.check_in, booking.check_out)
    held.reserved.lapsed.ids.each { Booking.cancel_lapsed!(it) }
    held
  end

  def self.already_booked!(booking)
    raise Kiosk::Server::Errors::Conflict,
          "room type #{booking.room_type_id} is already booked for #{booking.check_in}..#{booking.check_out} — " \
          'call availability for the room types still free'
  end
end
