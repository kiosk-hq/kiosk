# frozen_string_literal: true

# The cashier check, as a PSP-adapter decorator: before any capture, verify
# the agent-signed cart against the OPERATOR'S OWN quote. The wire verifies the
# mandate chain's internal consistency (cart total == payment amount, one
# currency across the chain) — it cannot know this hotel's currency or the
# price it quoted for a booking. The operator must count what lands on the
# counter:
#
#   1. the cart is denominated in the operator's currency (EUR);
#   2. it references exactly one booking ({"booking_id": ...} among the
#      line_items — see reserve_room's pay_hint);
#   3. its total equals the price the operator QUOTED for that booking
#      (bookings.total_cents, read by id) AND — when the cart carries priced
#      line items — the sum of those lines (internal arithmetic consistency).
#
# This is a MONETARY check only. It deliberately does NOT verify that the
# booking belongs to the payer: hoteling enforces settlement→booking ownership
# at USE time (confirm_booking Gate-1), and its isolation flow proves that B
# may pay for A's booking at the correct price and currency — the settlement is
# valid, yet Gate-1 still denies B's confirm_booking. Ownership is not a
# payment concern here; the counter only checks the money.
#
# Any mismatch rejects the capture (403 Forbidden); the mandate trail is
# persisted, nothing is charged.
class ValidatingBookingProvider
  def initialize(provider, currency:)
    @provider = provider
    @currency = currency.to_s.downcase
  end

  def capture(cart_mandate, payment_method: nil)
    validate!(cart_mandate)
    @provider.capture(cart_mandate, payment_method: payment_method)
  end

  def method_missing(name, *args, **kwargs, &block)
    @provider.public_send(name, *args, **kwargs, &block)
  end

  def respond_to_missing?(name, include_private = false)
    @provider.respond_to?(name, include_private) || super
  end

  private

  def validate!(cart)
    unless cart.currency.to_s.downcase == @currency
      deny "cart currency #{cart.currency.inspect} rejected — this operator prices in " \
           "#{@currency.upcase} (availability rows and reserve_room carry a currency field)"
    end

    entries = Array(cart.line_items)
    refs    = entries.filter_map { |li| li["booking_id"] || li[:booking_id] }.map(&:to_s).uniq
    deny "cart line_items must reference exactly one booking_id (see reserve_room's pay_hint)" unless refs.size == 1
    booking_id = refs.first

    conn    = ActiveRecord::Base.connection
    booking = conn.execute(
      "SELECT total_cents FROM public.bookings " \
      "WHERE id = #{conn.quote(booking_id)}::uuid " \
      "LIMIT 1"
    ).first
    deny "booking not found" if booking.nil?
    quoted = booking["total_cents"].to_i

    # Internal arithmetic consistency: if any line carries a per-unit price,
    # the cart's total must equal the sum of qty × price_cents across those
    # lines. Carts that carry no priced lines (e.g. the isolation-flow cart)
    # skip this sub-check and are guarded by the quoted-total check alone.
    priced = entries.select { |li| li["price_cents"] || li[:price_cents] }
    unless priced.empty?
      line_sum = priced.sum do |li|
        qty   = (li["qty"] || li[:qty]).to_i
        price = (li["price_cents"] || li[:price_cents]).to_i
        deny "each priced line needs a positive qty and price_cents" if qty <= 0 || price <= 0
        qty * price
      end
      unless cart.total_amount_cents.to_i == line_sum
        deny "cart total #{cart.total_amount_cents} does not equal the sum of its line items #{line_sum}"
      end
    end

    unless cart.total_amount_cents.to_i == quoted
      deny "cart total #{cart.total_amount_cents} does not equal the price quoted for this booking " \
           "#{quoted} — re-read availability and reserve_room's pay_hint"
    end
  end

  def deny(message)
    raise Kiosk::Server::Errors::Forbidden.new(message)
  end
end
