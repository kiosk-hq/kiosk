# frozen_string_literal: true

# The cashier check, as a PSP-adapter decorator: before any capture, verify
# the agent-signed cart against the OPERATOR'S OWN catalog. The wire verifies
# the mandate chain's internal consistency (cart total == payment amount, one
# currency across the chain) — it cannot know this shop's prices or currency.
# The operator must count what lands on the counter:
#
#   1. the cart is denominated in the operator's currency;
#   2. it references exactly one of the payer's own, not-yet-settled orders
#      (a {"order_id": ...} entry among line_items — see create_order's
#      pay_hint);
#   3. its item lines mirror that order exactly — same skus, same
#      quantities, prices as in the catalog at order time;
#   4. its total equals both the sum of those lines and the order's total.
#
# Any mismatch rejects the capture (403); the mandate trail is persisted,
# nothing is charged.
class ValidatingPaymentProvider
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
           "#{@currency.upcase} (the catalog carries a currency field)"
    end

    entries  = Array(cart.line_items)
    refs     = entries.filter_map { |li| li["order_id"] || li[:order_id] }.map(&:to_s).uniq
    deny "cart line_items must reference exactly one order_id (see create_order's pay_hint)" unless refs.size == 1
    order_id = refs.first

    conn  = ActiveRecord::Base.connection
    order = conn.execute(
      "SELECT id, total_cents FROM orders " \
      "WHERE id = #{conn.quote(order_id)}::uuid " \
      "AND user_id = #{conn.quote(cart.user_id.to_s)}::uuid " \
      "LIMIT 1"
    ).first
    deny "order not found or not yours" if order.nil?

    settled_filter = [{ order_id: order_id }].to_json
    settled = conn.execute(
      "SELECT 1 AS ok FROM kiosk.settlements pm " \
      "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
      "WHERE cm.line_items @> #{conn.quote(settled_filter)}::jsonb " \
      "LIMIT 1"
    ).first
    deny "order already settled" unless settled.nil?

    expected = conn.execute(
      "SELECT p.sku, oi.qty, p.price_cents " \
      "FROM order_items oi JOIN products p ON p.id = oi.product_id " \
      "WHERE oi.order_id = #{conn.quote(order_id)}::uuid"
    ).to_a.map { |r| [r["sku"].to_s, r["qty"].to_i, r["price_cents"].to_i] }.sort

    presented = entries.reject { |li| li["order_id"] || li[:order_id] }.map do |li|
      sku   = (li["sku"] || li[:sku]).to_s
      qty   = (li["qty"] || li[:qty]).to_i
      price = (li["price_cents"] || li[:price_cents]).to_i
      deny "each item line needs sku, qty, and price_cents (catalog price)" if sku.empty? || qty <= 0 || price <= 0
      [sku, qty, price]
    end.sort

    unless presented == expected
      deny "cart items do not mirror the order at catalog prices — re-read the catalog " \
           "and create_order's pay_hint"
    end

    line_sum = presented.sum { |(_, qty, price)| qty * price }
    unless cart.total_amount_cents.to_i == line_sum && line_sum == order["total_cents"].to_i
      deny "cart total #{cart.total_amount_cents} does not equal the order's catalog total " \
           "#{order["total_cents"]}"
    end
  end

  def deny(message)
    raise Kiosk::Server::Errors::Forbidden.new(message)
  end
end
