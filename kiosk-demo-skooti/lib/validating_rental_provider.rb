# frozen_string_literal: true

# The cashier check, as a PSP-adapter decorator: before any capture, verify
# the agent-signed cart against the OPERATOR'S OWN quote. The wire verifies the
# mandate chain's internal consistency (cart total == payment amount, one
# currency across the chain) — it cannot know this operator's currency or the
# price it quoted for a reservation. The operator must count what lands on the
# counter:
#
#   1. the cart is denominated in the operator's currency (EUR);
#   2. it references exactly one reservation ({"reservation_id": ...} among the
#      line_items — see reserve's pay_hint);
#   3. its total equals the price the operator QUOTED for that reservation AND
#      — when the cart carries priced line items — the sum of those lines
#      (internal arithmetic consistency).
#
# Skooti rentals are metered per-minute: there is no fixed total_cents stored on
# the reservation. The quote is derived — the reservation's scooter carries
# price_per_min_cents, and the pay step settles ONE minute upfront
# (price_per_min_cents × 1), mirroring reserve/rental_flow. So the quoted total
# for a reservation is that scooter's price_per_min_cents, read by joining the
# reservation to its scooter by id (NO user filter — ownership is not checked
# here).
#
# This is a MONETARY check only. It deliberately does NOT verify that the
# reservation belongs to the payer: skooti enforces settlement→reservation
# ownership at USE time (start_rental / rent_motorcycle Gate-1), and its
# isolation flow proves that B may pay for A's reservation at the correct price
# and currency — the settlement is valid, yet Gate-1 still denies B's
# start_rental. Ownership is not a payment concern here; the counter only
# checks the money. The KYC gate likewise lives at USE time and is untouched.
#
# Any mismatch rejects the capture (403 Forbidden); the mandate trail is
# persisted, nothing is charged.
class ValidatingRentalProvider
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
           "#{@currency.upcase} (the fleet catalog and reserve carry a currency field)"
    end

    entries = Array(cart.line_items)
    refs    = entries.filter_map { |li| li["reservation_id"] || li[:reservation_id] }.map(&:to_s).uniq
    deny "cart line_items must reference exactly one reservation_id (see reserve's pay_hint)" unless refs.size == 1
    reservation_id = refs.first

    # Quoted total = this reservation's scooter price_per_min_cents × 1 minute
    # (the upfront hold reserve/rental_flow settle). Join reservation → scooter
    # by id; no user_id filter — ownership is a USE-time gate, not the cashier's.
    conn  = ActiveRecord::Base.connection
    quote = conn.execute(
      "SELECT s.price_per_min_cents " \
      "FROM public.reservations r " \
      "JOIN public.scooters s ON s.id = r.scooter_id " \
      "WHERE r.id = #{conn.quote(reservation_id)}::uuid " \
      "LIMIT 1"
    ).first
    deny "reservation not found" if quote.nil?
    quoted = quote["price_per_min_cents"].to_i

    # Internal arithmetic consistency: if any line carries a per-unit price,
    # the cart's total must equal the sum of qty × price_cents across those
    # lines. Carts with no priced lines (e.g. the isolation-flow cart) skip
    # this sub-check and are guarded by the quoted-total check alone.
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
      deny "cart total #{cart.total_amount_cents} does not equal the operator's quoted rental price " \
           "#{quoted} — re-read the fleet catalog and reserve's pay_hint"
    end
  end

  def deny(message)
    raise Kiosk::Server::Errors::Forbidden.new(message)
  end
end
