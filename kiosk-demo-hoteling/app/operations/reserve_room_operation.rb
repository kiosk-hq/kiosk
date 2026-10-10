# frozen_string_literal: true

# Holds one room type for one stay for the principal: the booking and the
# engine's reservation row, together. Raises a wire error on a refusal.
class ReserveRoomOperation
  def self.call(principal_id:, agent_id:, property_id:, room_type_id:, check_in:, check_out:)
    booking = Booking.new(user_id: principal_id, property_id:, room_type: RoomType.find_by(id: room_type_id),
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

    RoomHold.create!(user_id: principal_id, agent_id: agent_id, resource_kind: RoomHold::RESOURCE_KIND,
                     resource_id: booking.id, args: {}, expires_at: RoomHold::PAY_BY.from_now)

    nightly_price_cents = booking.room_type.nightly_price_cents
    {
      booking_id:          booking.id,
      total_cents:         booking.total_cents,
      currency:            "eur",
      nights:              booking.nights,
      nightly_price_cents: nightly_price_cents,
      pay_hint:            "pay in EUR with a cart mandate whose total_amount_cents == #{booking.total_cents} " \
                           "and whose line_items reference this booking: one " \
                           "{\"qty\": #{booking.nights}, \"price_cents\": #{nightly_price_cents}, " \
                           "\"booking_id\": \"#{booking.id}\"} entry — the operator verifies currency and " \
                           "total against its quote before charging",
    }
  end

  def self.already_booked!(room_type_id, check_in, check_out)
    raise Kiosk::Server::Errors::Conflict,
          "room type #{room_type_id} is already booked for #{check_in}..#{check_out} — " \
          "call availability again for the room types still free on those dates"
  end
end
