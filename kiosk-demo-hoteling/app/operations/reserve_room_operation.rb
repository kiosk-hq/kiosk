# frozen_string_literal: true

# Holds one room type for one stay for the principal: the booking and the
# engine's reservation row, together. Raises a wire error on a refusal.
class ReserveRoomOperation
  def self.call(principal_id:, agent_id:, property_id:, room_type_id:, check_in:, check_out:)
    nightly_price_cents = RoomType.where(id: room_type_id, property_id: property_id).pick(:nightly_price_cents)
    WireArguments.refuse("room type not found for this property") if nightly_price_cents.nil?

    check_in, check_out = WireArguments.stay(check_in, check_out)
    WireArguments.bookable!(check_in, zone: WireArguments.zone_for(property_id))

    nights      = (check_out - check_in).to_i
    total_cents = nights * nightly_price_cents
    WireArguments.priceable_total!(total_cents, nights)

    if Booking.live.where(room_type_id: room_type_id).overlapping(check_in, check_out).exists?
      already_booked!(room_type_id, check_in, check_out)
    end

    # The exclusion constraint answers the race the check above loses.
    booking = begin
      Booking.create!(user_id: principal_id, property_id: property_id, room_type_id: room_type_id,
                      check_in: check_in, check_out: check_out, total_cents: total_cents)
    rescue ActiveRecord::ExclusionViolation
      already_booked!(room_type_id, check_in, check_out)
    end

    RoomHold.create!(user_id: principal_id, agent_id: agent_id, resource_kind: RoomHold::RESOURCE_KIND,
                     resource_id: booking.id, args: {}, expires_at: RoomHold::PAY_BY.from_now)

    {
      booking_id:          booking.id,
      total_cents:         total_cents,
      currency:            "eur",
      nights:              nights,
      nightly_price_cents: nightly_price_cents,
      pay_hint:            "pay in EUR with a cart mandate whose total_amount_cents == #{total_cents} " \
                           "and whose line_items reference this booking: one " \
                           "{\"qty\": #{nights}, \"price_cents\": #{nightly_price_cents}, " \
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
