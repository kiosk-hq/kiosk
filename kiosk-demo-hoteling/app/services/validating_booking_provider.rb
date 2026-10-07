# frozen_string_literal: true

# The cashier check: before any capture, the agent-signed cart is checked
# against the price this hotel QUOTED for the booking it names — EUR, exactly
# one `booking_id` (reserve_room's pay_hint), a total equal to
# `bookings.total_cents` and to the sum of any priced lines. Any mismatch is a
# 403 and nothing is charged.
#
# MONETARY ONLY: whether the payer owns the booking is confirm_booking's Gate 1.
#
# The claim around it — one capture per booking, `paid` the instant the capture
# returns — is the engine's {Kiosk::Server::PaymentClaim}.
class ValidatingBookingProvider < Kiosk::Server::PaymentClaim
  def initialize(psp, currency:)
    super(psp, currency: currency, table: "bookings", reference: "booking_id",
               query: "my_bookings", payer_column: "paid_by_user_id")
  end

  private

  def check_cart!(cart, booking_id)
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

    quoted = Booking.where(id: booking_id).pick(:total_cents).to_i
    return if cart.total_amount_cents.to_i == quoted

    deny "cart total #{cart.total_amount_cents} does not equal the price quoted for this booking " \
         "#{quoted} — re-read availability and reserve_room's pay_hint"
  end

  # The owner hears about it — B may pay A's booking, and A has nothing to
  # poll — and the property starts deciding.
  def paid!(booking_id)
    owner_id = Booking.where(id: booking_id).pick(:user_id)
    if owner_id
      Kiosk::Server::Events.emit(
        topic: :booking_payment, subject: booking_id, identity_scope: [owner_id],
        data: { "booking_id" => booking_id, "payment_state" => "paid" },
      )
    end
    schedule_property_decision!(booking_id)
  end

  # `decision_due_at` makes the wait visible in the row. A zero wait decides
  # inline, so a flow can assert on it without racing a thread pool.
  def schedule_property_decision!(booking_id)
    wait = Rails.configuration.x.hoteling.decision_delay_seconds.to_i
    Booking.where(id: booking_id).update_all(decision_due_at: Time.current + wait)
    return PropertyDecisionJob.new.perform(booking_id) if wait.zero?

    PropertyDecisionJob.set(wait: wait.seconds).perform_later(booking_id)
  end
end
