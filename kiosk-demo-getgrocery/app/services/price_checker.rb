# frozen_string_literal: true

# What `c.cart_price_checker` answers: the order's catalog total, once the
# cart's item lines mirror that order exactly — same skus, same quantities, the
# catalog prices at order time. Kiosk::Server::PaymentClaim checks the rest.
module PriceChecker
  def self.call(order_id, lines)
    presented = lines.map do |li|
      sku   = li["sku"].to_s
      qty   = li["qty"].to_i
      price = li["price_cents"].to_i
      return "each item line needs sku, qty, and price_cents (catalog price)" if sku.empty? || qty <= 0 || price <= 0

      [sku, qty, price]
    end
    return "cart items do not mirror the order at catalog prices — re-read the catalog and create_order's pay_hint" \
      unless presented.sort == ordered(order_id)

    Order.where(id: order_id).pick(:total_cents)
  end

  def self.ordered(order_id)
    OrderItem.joins(:product).where(order_id: order_id)
             .pluck(Product.arel_table[:sku], :qty, Product.arel_table[:price_cents])
             .map { |sku, qty, price_cents| [sku.to_s, qty.to_i, price_cents.to_i] }
             .sort
  end
end
