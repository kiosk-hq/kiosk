# frozen_string_literal: true

# What `c.cart_price_checker` answers: the order's total, once the cart's item
# lines mirror that order exactly — same skus, same quantities, the prices it
# was ordered at — and the shelf still holds it. Kiosk::Server::PaymentClaim checks the rest.
module PriceChecker
  def self.call(order_id, lines)
    presented = presented(lines)
    return 'each item line needs sku, qty, and price_cents (the price it was ordered at)' unless presented.all? { well_formed?(*it) }

    order = Order.includes(order_items: :product).find(order_id)
    return "cart items do not mirror the order at the prices it was ordered at — follow create_order's pay_hint" \
      unless presented.sort == ordered(order)

    short = order.shortfall
    return "sold out since the order was placed — #{short.join('; ')} — place a new order" if short.any?

    order.total_cents
  end

  def self.presented(lines) = lines.map { [it['sku'].to_s, it['qty'].to_i, it['price_cents'].to_i] }

  def self.well_formed?(sku, qty, price) = !sku.empty? && qty.positive? && price.positive?

  def self.ordered(order) = order.order_items.map { [it.product.sku, it.qty, it.price_cents] }.sort
end
