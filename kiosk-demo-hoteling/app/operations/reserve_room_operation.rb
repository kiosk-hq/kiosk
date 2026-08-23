# frozen_string_literal: true

# reserve_room — a hold on one room type for one stay, for the authenticated
# principal: the domain `bookings` row and the engine's `kiosk.reservations` row
# together, in one transaction.
#
# It is an Operation and not a controller method because of what is IN it: the
# three-part inventory guard (K-690) whose middle part is an INSERT that may
# raise, wrapped in a transaction. A `render` in the middle of that is what every
# earlier slice had to reason about; here the transaction answers a VALUE and the
# controller decides what a value looks like on the wire.
class ReserveRoomOperation
  # @param principal_id [String] the account the wire resolved. NEVER an argument
  #   off the request: `reserve_room` deliberately IGNORES a forged `user_id` in
  #   the body, and it can do that precisely because the value is passed in from
  #   the identity rather than read out of the params (the redteam battery's
  #   ForgedUserId beat asserts the row lands under the caller).
  #
  #   An INSERT is the one place the principal must be spelled in Ruby. Every READ
  #   scopes with `Booking.owned_by_current_principal`, which never names the
  #   principal at all because a WHERE has a predicate to hide it in; an INSERT has
  #   no predicate, so it must supply the value. Both are un-forgeable for the same
  #   reason — the identity is resolved from the Rack env the wire built, which no
  #   request argument can write — but only the first keeps the database as the
  #   authority. Moving the column DEFAULT to `kiosk.current_user_id()` would close
  #   the gap; that is a migration, not part of a handler conversion (the atablefor
  #   note, unchanged).
  # @param agent_id [String, nil] the ACTING agent, recorded on the hold row.
  def self.call(principal_id:, agent_id:, property_id:, room_type_id:, check_in:, check_out:)
    # The four presence checks, in the order the raw handler asked them, so a
    # request missing more than one is still told about the same one first.
    prop_id, refusal = WireArguments.integer(property_id, field: "property_id", hint: WireArguments::HINT_PROPERTY_ID)
    return refusal if refusal

    rt_id, refusal = WireArguments.integer(room_type_id, field: "room_type_id", hint: WireArguments::HINT_ROOM_TYPE_ID)
    return refusal if refusal

    return WireArguments.missing("check_in")  if check_in.blank?
    return WireArguments.missing("check_out") if check_out.blank?

    # The chosen room type must exist AT the chosen property. `pick` is a
    # projection of the one column the quote needs, not a loaded model — the raw
    # SELECT also read `id` and `name` and used neither.
    nightly_price_cents = RoomType.where(id: rt_id, property_id: prop_id).pick(:nightly_price_cents)
    if nightly_price_cents.nil?
      return OperationResult.refused(code: "bad_request", message: "room type not found for this property")
    end

    # Parsed AFTER the room-type lookup, which is where the raw handler parsed
    # them — so a request that is wrong about both is told about the room first,
    # exactly as before.
    dates, refusal = WireArguments.stay_dates(check_in, check_out)
    return refusal if refusal

    ci, co = dates
    unless co > ci
      return OperationResult.refused(code: "bad_request", message: "check_out must be after check_in")
    end

    # ── K-969: A ROOM-NIGHT IN THE PAST IS REFUSED, NOT MERELY UNAVAILABLE ──
    # `availability` already answers nothing for these dates, and this is the
    # belt to that braces: an assistant may name a date it never read from an
    # availability response — the finding was filed because `check_in:
    # "1900-01-01"` answered 200 with a real booking and a real quote. The
    # refusal comes from the SAME guard the two read verbs use, so the offer and
    # the sale cannot come to disagree about where the floor is. See
    # {WireArguments.past_stay} for what «past» means here and why today counts
    # as bookable.
    refusal = WireArguments.past_stay(ci)
    return refusal if refusal

    nights      = (co - ci).to_i
    total_cents = nights * nightly_price_cents

    # A stay whose price does not fit the column is refused here, before the
    # transaction, rather than crashing on INSERT (K-968).
    refusal = WireArguments.priceable_total(total_cents, nights)
    return refusal if refusal

    # This `transaction` JOINS the one Kiosk::Server::SessionContext already
    # opened around the whole wire request (the GUCs are SET LOCAL in it), so it
    # opens no second transaction and a `return` out of it is an ordinary method
    # return, not a non-local exit from a real transaction block.
    Booking.transaction do
      # ── Finite inventory: the room-night must still be free (K-690) ─────────
      # `availability` defines the invariant this action sells against — a room
      # type is offered only while no live booking overlaps the requested nights
      # — and both now consult the SAME `Booking.overlapping` scope, so they can
      # no longer drift apart. Three parts, unchanged: a pre-check that answers a
      # clean 409 an assistant can act on, a database EXCLUDE constraint that
      # makes the race unrepresentable, and a rescue that turns the lost race
      # into that same 409.
      if Booking.live.where(room_type_id: rt_id).overlapping(ci, co).exists?
        return already_booked(rt_id, ci, co)
      end

      booking_id =
        begin
          # `insert!` and NOT `create!`, deliberately, and the reason is a wire
          # answer rather than taste. The rescue below depends on WHICH exception
          # class arrives. `create!` interposes validations, so `belongs_to :user`
          # (required by default) would turn a principal with no `users` row from
          # the `ActiveRecord::InvalidForeignKey` Postgres raises — unmapped in
          # `rescue_responses`, so re-raised and wrapped `action_failed`/500,
          # which is what the raw INSERT did — into a `RecordInvalid`, which
          # Rails maps to 422 and the handler mixin's `rescue_from` floor renders
          # as a 400. A 500 silently becoming a 400 for an unrelated input is
          # exactly the class of change this conversion must not make. Measured
          # on this model, not assumed: `insert!` → InvalidForeignKey, `create!`
          # → RecordInvalid.
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
          # Lost the race for the same room-night —
          # bookings_no_overlapping_room_nights caught it. Same answer as the
          # pre-check, so a concurrent caller and a slow caller cannot tell the
          # two apart.
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

  # Both halves of the double-booking guard answer with the SAME sentence, so an
  # assistant cannot tell (and need not care) which one caught it.
  def self.already_booked(room_type_id, check_in, check_out)
    OperationResult.refused(
      code:    "conflict",
      message: "room type #{room_type_id} is already booked for #{check_in}..#{check_out} — " \
               "call availability again for the room types still free on those dates",
    )
  end
  private_class_method :already_booked
end
