# frozen_string_literal: true

# reserve_room — a hold on one room type for one stay, for the authenticated
# principal: the domain `bookings` row and the engine's `kiosk.reservations` row
# together, in one transaction.
#
# An Operation and not a controller method because of what is IN it: a
# three-part inventory guard (K-690) wrapped in a transaction. The transaction
# answers a VALUE; the controller decides what a value looks like on the wire.
class ReserveRoomOperation
  # @param principal_id [String] the account the wire resolved — NEVER an
  #   argument off the request, which is what makes a forged `user_id` in the
  #   body inert (the redteam battery's ForgedUserId beat asserts it). An INSERT
  #   is the one place the principal must be spelled in Ruby: every READ hides it
  #   in a WHERE predicate (`Booking.owned_by_current_principal`), an INSERT has
  #   none. Moving the column DEFAULT to `kiosk.current_user_id()` would make the
  #   database the authority; that is a migration, not a handler change.
  def self.call(principal_id:, agent_id:, property_id:, room_type_id:, check_in:, check_out:)
    prop_id, refusal = WireArguments.integer(property_id, field: "property_id", hint: WireArguments::HINT_PROPERTY_ID)
    return refusal if refusal

    rt_id, refusal = WireArguments.integer(room_type_id, field: "room_type_id", hint: WireArguments::HINT_ROOM_TYPE_ID)
    return refusal if refusal

    return WireArguments.missing("check_in")  if check_in.blank?
    return WireArguments.missing("check_out") if check_out.blank?

    # The chosen room type must exist AT the chosen property; `pick` projects the
    # one column the quote needs rather than loading a model.
    nightly_price_cents = RoomType.where(id: rt_id, property_id: prop_id).pick(:nightly_price_cents)
    if nightly_price_cents.nil?
      return OperationResult.refused(code: "bad_request", message: "room type not found for this property")
    end

    dates, refusal = WireArguments.stay_dates(check_in, check_out)
    return refusal if refusal

    ci, co = dates
    unless co > ci
      return OperationResult.refused(code: "bad_request", message: "check_out must be after check_in")
    end

    # K-969: the SAME floor the read verbs apply, so the offer and the sale
    # cannot disagree about it — an assistant may name a date it never read from
    # an availability response. See {WireArguments.past_stay} for what «past»
    # means here and why today counts as bookable.
    refusal = WireArguments.past_stay(ci)
    return refusal if refusal

    nights      = (co - ci).to_i
    total_cents = nights * nightly_price_cents

    # A stay whose price does not fit the column is refused here, before the
    # transaction, rather than crashing on INSERT (K-968).
    refusal = WireArguments.priceable_total(total_cents, nights)
    return refusal if refusal

    # JOINS the transaction Kiosk::Server::SessionContext already opened around
    # the whole request (the GUCs are SET LOCAL in it), so this opens no second
    # one and a `return` out of it is an ordinary method return.
    Booking.transaction do
      # ── Finite inventory: the room-night must still be free (K-690) ─────────
      # Three parts: this pre-check, which answers a clean 409; a database
      # EXCLUDE constraint that makes the race unrepresentable; and the rescue
      # below, which turns a lost race into the same 409. The predicate is
      # `availability`'s own scope, so offer and sale cannot drift apart.
      if Booking.live.where(room_type_id: rt_id).overlapping(ci, co).exists?
        return already_booked(rt_id, ci, co)
      end

      booking_id =
        begin
          # `insert!` and NOT `create!`: the rescue below depends on WHICH
          # exception arrives. `create!` interposes validations, so a principal
          # with no `users` row would raise `RecordInvalid` (422, rendered 400)
          # instead of `ActiveRecord::InvalidForeignKey`, which is unmapped and
          # surfaces as `action_failed`/500. Measured, not assumed.
          Booking.insert!(
            { user_id:      principal_id,
              property_id:  prop_id,
              room_type_id: rt_id,
              check_in:     ci,
              check_out:    co,
              total_cents:  total_cents,
              status:       Booking::RESERVED },
            returning: %i[id],
          ).first["id"]
        rescue ActiveRecord::ExclusionViolation
          # Lost the race — bookings_no_overlapping_room_nights caught it. Same
          # answer as the pre-check, so the two cases are indistinguishable.
          return already_booked(rt_id, ci, co)
        end

      # The engine's reserve-then-pay row, bound to the booking, stamped with the
      # pay-by deadline nothing yet enforces — see {RoomHold} (K-936).
      RoomHold.insert!(
        { user_id:       principal_id,
          agent_id:      agent_id,
          resource_kind: RoomHold::RESOURCE_KIND,
          resource_id:   booking_id,
          args:          {},
          expires_at:    RoomHold::PAY_BY.from_now },
      )

      OperationResult.ok({
        booking_id:          booking_id,
        total_cents:         total_cents,
        currency:            "eur",
        nights:              nights,
        nightly_price_cents: nightly_price_cents,
        pay_hint:            "pay in EUR with a cart mandate whose total_amount_cents == #{total_cents} " \
                             "and whose line_items reference this booking: one " \
                             "{\"sku\", \"qty\": #{nights}, \"price_cents\": #{nightly_price_cents}, " \
                             "\"booking_id\": \"#{booking_id}\"} entry — the operator verifies currency and " \
                             "total against its quote before charging",
      })
    end
  end

  # Both halves of the double-booking guard answer with the SAME sentence.
  def self.already_booked(room_type_id, check_in, check_out)
    OperationResult.refused(
      code:    "conflict",
      message: "room type #{room_type_id} is already booked for #{check_in}..#{check_out} — " \
               "call availability again for the room types still free on those dates",
    )
  end
  private_class_method :already_booked
end
