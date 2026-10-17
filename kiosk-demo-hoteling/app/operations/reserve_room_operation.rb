# frozen_string_literal: true

# Holds one room type for one stay for the customer: the booking and the
# engine's reservation row, together. Returns the booking; raises a wire error on a refusal.
class ReserveRoomOperation
  def self.call(customer_id:, agent_id:, room_type_id:, check_in:, check_out:)
    booking = Booking.new(user_id: customer_id, room_type: RoomType.find_by(id: room_type_id),
                          check_in: Date.iso8601(check_in), check_out: Date.iso8601(check_out))
    booking.validate!
    booking.total_cents = booking.nights * booking.room_type.nightly_price_cents

    if Booking.live.where(room_type_id: room_type_id).overlapping(booking.check_in, booking.check_out).exists?
      already_booked!(room_type_id, booking.check_in, booking.check_out)
    end

    # The exclusion constraint answers the race the check above loses.
    begin
      booking.save!
    rescue ActiveRecord::ExclusionViolation
      already_booked!(room_type_id, booking.check_in, booking.check_out)
    end

    RoomHold.create!(user_id: customer_id, agent_id: agent_id, resource_kind: RoomHold::RESOURCE_KIND,
                     resource_id: booking.id, args: {}, expires_at: RoomHold::PAY_BY.from_now)
    booking
  end

  def self.already_booked!(room_type_id, check_in, check_out)
    raise Kiosk::Server::Errors::Conflict,
          "room type #{room_type_id} is already booked for #{check_in}..#{check_out} — " \
          "call availability for the room types still free"
  end
end
