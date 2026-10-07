# frozen_string_literal: true

# The cashier check: before any capture, the agent-signed cart is checked
# against the price this operator QUOTED for the reservation it names — EUR,
# exactly one `reservation_id` (reserve's pay_hint), a total equal to the
# scooter's per-minute price (the one minute the pay step settles upfront) and
# to the sum of any priced lines. Any mismatch is a 403 and nothing is charged.
#
# MONETARY ONLY: whether the payer owns the reservation is start_rental's Gate 1.
#
# The claim around it — one capture per reservation, `paid` the instant the
# capture returns — is the engine's {Kiosk::Server::PaymentClaim}.
class ValidatingRentalProvider < Kiosk::Server::PaymentClaim
  def initialize(psp, currency:)
    super(psp, currency: currency, table: "reservations", reference: "reservation_id",
               query: "my_reservations", payer_column: "paid_by_user_id")
  end

  private

  def check_cart!(cart, reservation_id)
    priced = Array(cart.line_items).select { |li| li["price_cents"] }
    unless priced.empty?
      line_sum = priced.sum do |li|
        qty   = li["qty"].to_i
        price = li["price_cents"].to_i
        deny "each priced line needs a positive qty and price_cents" if qty <= 0 || price <= 0
        qty * price
      end
      unless cart.total_amount_cents.to_i == line_sum
        deny "cart total #{cart.total_amount_cents} does not equal the sum of its line items #{line_sum}"
      end
    end

    quoted = Reservation.joins(:scooter).where(id: reservation_id).pick(Scooter.arel_table[:price_per_min_cents]).to_i
    return if cart.total_amount_cents.to_i == quoted

    deny "cart total #{cart.total_amount_cents} does not equal the operator's quoted rental price " \
         "#{quoted} — re-read the fleet catalog and reserve's pay_hint"
  end

  # The owner hears about it: the payer may be somebody else.
  def paid!(reservation_id)
    owner_id = Reservation.where(id: reservation_id).pick(:user_id)
    return unless owner_id

    Kiosk::Server::Events.emit(
      topic: :booking_payment, subject: reservation_id, identity_scope: [owner_id],
      data: { "reservation_id" => reservation_id, "payment_state" => "paid" },
    )
  end
end
