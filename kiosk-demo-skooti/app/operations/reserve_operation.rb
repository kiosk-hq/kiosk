# frozen_string_literal: true

# reserve — a hold on one fleet vehicle for the authenticated principal, and the
# quote the assistant must sign its cart against.
#
# Deliberately OPEN TO EVERY VEHICLE, licence-free scooter and KYC-gated
# motorcycle alike: one reservation shape serves both rental verbs, and the
# licence check belongs at USE time next to the ownership and payment gates
# (K-687). Nothing here is a statement that the caller may ride what it books.
class ReserveOperation
  # @param principal_id [String] the account the wire resolved. NEVER an
  #   argument off the request: `reserve` deliberately IGNORES a forged
  #   `user_id` in the body, and it can do that precisely because the value is
  #   passed in from the identity rather than read out of the params (the
  #   redteam battery's ForgedUserId beat asserts the row lands under the
  #   caller).
  #
  #   An INSERT is the one place the principal must be spelled in Ruby. Every
  #   READ scopes with `Reservation.owned_by_current_principal`, which never
  #   names the principal at all because a WHERE has a predicate to hide it in;
  #   an INSERT has no predicate, so it must supply the value. Both are
  #   un-forgeable for the same reason — the identity is resolved from the Rack
  #   env the wire built, which no request argument can write — but only the
  #   first keeps the database as the authority. Moving the column DEFAULT to
  #   `kiosk.current_user_id()` would close the gap; that is a migration, not
  #   part of a handler conversion.
  #
  # @param scooter_code [Object] the raw wire value. PRESENCE is the
  #   controller's question (see Kiosk::RentalsController#reserve): a key that
  #   is absent is a different answer from a key that is present and null, and
  #   only the request knows which it was.
  def self.call(principal_id:, scooter_code:)
    # `pick`, not a loaded model: this is a projection of the three columns the
    # quote needs. The raw SELECT read exactly these three. `find_by` would work
    # and `find_by!` would not — the bang form's RecordNotFound is mapped to 404
    # by the mixin's `rescue_from` floor, which would turn this operator's
    # 400 "scooter not found" into Rails' 404 and change the answer.
    scooter = Scooter.where(code: scooter_code.to_s).pick(:id, :code, :price_per_min_cents)
    if scooter.nil?
      return OperationResult.refused(code: "bad_request", message: "scooter not found: #{scooter_code}")
    end

    scooter_id, code, price_per_min_cents = scooter

    # `insert!` and NOT `create!`, deliberately, and the reason is a wire answer
    # rather than taste. `create!` interposes validations, so `belongs_to :user`
    # (required by default) would turn a principal with no `users` row from the
    # `ActiveRecord::InvalidForeignKey` Postgres raises — unmapped in
    # `rescue_responses`, so re-raised and wrapped `action_failed`/500, which is
    # what the raw INSERT did — into a `RecordInvalid`, which Rails maps to 422
    # and the handler mixin's floor renders as a 400. A 500 silently becoming a
    # 400 for an unrelated input is exactly the class of change this conversion
    # must not make. Measured on THIS model, not assumed: `insert!` →
    # InvalidForeignKey ("violates foreign key constraint"), `create!` →
    # RecordInvalid ("Validation failed: User must exist").
    #
    # The timestamps were `now()` — the DATABASE clock — and are the app clock
    # now, because `insert_all` type-casts its values and has no way to pass an
    # SQL expression through. `my_reservations` orders by `created_at`, and app
    # and database run on one host in every demo and on the deployed box, so the
    # two clocks are the same clock.
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
