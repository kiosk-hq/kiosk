# frozen_string_literal: true

# reserve — a hold on one fleet vehicle for the authenticated principal, and the
# quote the assistant must sign its cart against.
#
# Deliberately OPEN TO EVERY VEHICLE, licence-free scooter and KYC-gated
# motorcycle alike: one reservation shape serves both rental verbs, and the
# licence check belongs at USE time next to the ownership and payment gates
# (K-687). Booking is not a statement that the caller may ride what it books.
class ReserveOperation
  # @param principal_id [String] the account the wire resolved, NEVER an argument
  #   off the request: `reserve` ignores a forged `user_id` in the body precisely
  #   because the value comes from the identity rather than from the params (the
  #   redteam battery's ForgedUserId beat asserts the row lands under the caller).
  #
  #   An INSERT is the one place the principal must be spelled in Ruby: every
  #   READ hides it in `owned_by_current_principal`'s WHERE predicate, and an
  #   INSERT has no predicate to hide it in.
  #
  # @param scooter_code [Object] the raw wire value. PRESENCE is the controller's
  #   question (see Kiosk::RentalsController#reserve): an absent key is a
  #   different answer from a key present and null, and only the request knows.
  def self.call(principal_id:, scooter_code:)
    # `pick`, not a loaded model: a projection of the three columns the quote
    # needs. `find_by!` would NOT do — its RecordNotFound is mapped to 404 by the
    # mixin's floor, turning this operator's 400 into Rails' 404.
    scooter = Scooter.where(code: scooter_code.to_s).pick(:id, :code, :price_per_min_cents)
    if scooter.nil?
      return OperationResult.refused(code: "bad_request", message: "scooter not found: #{scooter_code}")
    end

    scooter_id, code, price_per_min_cents = scooter

    # `insert!` and NOT `create!`, and the reason is a wire answer rather than
    # taste: `create!` interposes validations, so `belongs_to :user` turns the
    # `InvalidForeignKey` Postgres raises for a principal with no `users` row —
    # unmapped, so a 500 — into a `RecordInvalid` Rails maps to 422 and the
    # mixin's floor renders as a 400.
    #
    # The timestamps are the APP clock: `insert_all` type-casts its values and
    # cannot pass an SQL expression through. `my_reservations` orders by
    # `created_at`, and app and database share a host, so it is the same clock.
    now = Time.current
    reservation_id = Reservation.insert!(
      { user_id:    principal_id,
        scooter_id: scooter_id,
        status:     Reservation::RESERVED,
        created_at: now,
        updated_at: now },
      returning: %i[id],
    ).first["id"]

    OperationResult.ok({
      reservation_id:      reservation_id,
      scooter_code:        code,
      price_per_min_cents: price_per_min_cents,
      currency:            "eur",
      pay_hint:            "pay in EUR with a cart mandate whose total_amount_cents == " \
                           "#{price_per_min_cents} (the quoted upfront minute) and whose line_items " \
                           "reference this reservation: one {\"sku\", \"qty\": 1, \"price_cents\": " \
                           "#{price_per_min_cents}, \"reservation_id\": \"#{reservation_id}\"} entry — " \
                           "the operator verifies currency and total against its quote before charging",
    })
  end
end
