# frozen_string_literal: true

# Holds one room type for one stay for the customer: the booking and the
# engine's reservation row, together. Raises a wire error on a refusal.
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

    nightly_price_cents = booking.room_type.nightly_price_cents
    {
      booking_id:          booking.id,
      total_cents:         booking.total_cents,
      currency:            "eur",
      nights:              booking.nights,
      nightly_price_cents: nightly_price_cents,
      pay_hint:            "sign a cart mandate in EUR with total_amount_cents #{booking.total_cents} and " \
                           "one line item {\"qty\": #{booking.nights}, \"price_cents\": #{nightly_price_cents}, " \
                           "\"booking_id\": \"#{booking.id}\"}, then call pay",
    }
  end

  def self.already_booked!(room_type_id, check_in, check_out)
    raise Kiosk::Server::Errors::Conflict,
          "room type #{room_type_id} is already booked for #{check_in}..#{check_out} — " \
          "call availability for the room types still free"
  end
end
