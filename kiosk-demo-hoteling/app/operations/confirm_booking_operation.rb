# frozen_string_literal: true

# confirm_booking — turn a paid-for hold into a confirmed stay and hand back the
# reference the guest gives at the desk.
#
# TWO GATES, and they are separable on purpose: Gate 1 is OWNERSHIP (this
# booking, this principal, still reserved) and Gate 2 is PAYMENT (a settlement
# whose cart references this booking). The isolation flow proves Gate 1 alone by
# having B genuinely satisfy Gate 2 for A's booking and still be refused.
class ConfirmBookingOperation
  def self.call(booking_id:)
    return WireArguments.missing("booking_id") if booking_id.blank?

    # K-581/K-582: this id used to be cast `::uuid`, and a malformed one made
    # Postgres raise InvalidTextRepresentation — not a Kiosk error, so it escaped
    # as a raw 500 leaking "invalid input syntax for type uuid" for what is
    # plainly a client mistake. The guard got MORE load-bearing when the SQL
    # became ActiveRecord (K-654), exactly as atablefor's did: `where(id: junk)`
    # does not raise, because ActiveRecord's uuid type quietly casts an
    # unparseable value to NULL, which matches no row — so without this check a
    # typo would be reported as an OWNERSHIP refusal (403) instead of a shape one
    # (400). A well-formed but foreign id still gets the 403, so the shape check
    # never softens the access answer.
    unless UuidCheck.valid?(booking_id)
      return OperationResult.refused(
        code:    "bad_request",
        message: "booking_id #{booking_id.to_s.inspect} is not a uuid — pass the `booking_id` " \
                 "that reserve_room returned (also listed by my_bookings)",
      )
    end

    # Joins the request's SessionContext transaction; opens no second one.
    Booking.transaction do
      # ── Gate 1: booking belongs to principal AND status = 'reserved' ────────
      # Owner-scoped by the GUC predicate, so a cross-principal confirm finds
      # nothing. Deliberately ONE answer for "no such booking", "not yours" and
      # "already confirmed": distinguishing them would let a caller enumerate
      # other principals' booking ids. `exists?`, not `find_by!` — the bang form
      # raises RecordNotFound, which Rails maps to 404 and the mixin's
      # `rescue_from` floor would render as `not_found`, telling a prober that
      # the id is unknown. That is the tudu reasoning and it applies verbatim.
      mine = Booking.owned_by_current_principal.where(id: booking_id, status: Booking::RESERVED)
      unless mine.exists?
        return OperationResult.refused(code: "forbidden", message: "booking not found or not yours")
      end

      # ── Gate 2: a settlement of THIS principal whose cart references THIS
      # booking. The JOIN and the jsonb containment are unchanged; what changed
      # is that the booking id is a quoted value rather than a fragment.
      paid = Settlement.of_current_principal
                       .joins(:cart_mandate)
                       .merge(CartMandate.referencing(booking_id))
      unless paid.exists?
        return OperationResult.refused(code: "forbidden", message: "no settlement for this booking")
      end

      # ── All gates passed: confirm ───────────────────────────────────────────
      # K-698: the code is PERSISTED by this UPDATE and read back OUT of the row,
      # so what the assistant is handed is provably what the hotel stored. It used
      # to be a `SecureRandom.uuid` minted for the response only, against a table
      # with no such column — a booking reference the desk could never match.
      #
      # COALESCE survives verbatim, as an Arel function rather than a fragment, so
      # an already-coded booking keeps its code: today Gate 1 makes a re-confirm a
      # 403, but the reference has to be stable no matter what that gate does
      # later. What did NOT survive is `RETURNING confirmation_code` — Rails 8.1's
      # `update_all` has no returning: option — so the read-back is a second
      # statement in the SAME transaction, against the same owner-scoped relation.
      # The property that matters is unchanged (the value is read FROM the row,
      # never minted for the response); what is lost is one round trip.
      code = SecureRandom.uuid
      mine.update_all(
        status:            Booking::CONFIRMED,
        confirmation_code: Arel::Nodes::NamedFunction.new(
          "COALESCE", [Booking.arel_table[:confirmation_code], Arel::Nodes.build_quoted(code)],
        ),
        updated_at:        Time.current,
      )

      OperationResult.ok({
        booking_id:        booking_id,
        status:            "confirmed",
        confirmation_code: Booking.owned_by_current_principal.where(id: booking_id).pick(:confirmation_code),
      })
    end
  end
end
