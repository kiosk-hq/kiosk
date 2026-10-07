# frozen_string_literal: true

# The cashier check: before any capture, the agent-signed cart is checked
# against this shop's own catalog. The wire verifies the mandate chain's
# internal consistency but cannot know this shop's prices, so the operator
# counts what lands on the counter:
#
#   1. the cart is denominated in the operator's currency;
#   2. it references exactly one of the payer's own, not-yet-paid orders
#      (an {"order_id": ...} entry among line_items — see create_order's
#      pay_hint);
#   3. its item lines mirror that order exactly — same skus, same
#      quantities, prices as in the catalog at order time;
#   4. its total equals both the sum of those lines and the order's total.
#
# Any mismatch is a 403 and nothing is charged. The claim around it — one
# capture per order, `paid` the instant the capture returns — is the engine's
# {Kiosk::Server::PaymentClaim}.
class ValidatingPaymentProvider < Kiosk::Server::PaymentClaim
  def initialize(psp, currency:)
    super(psp, currency: currency, table: "orders", reference: "order_id", query: "my_orders",
               status_column: "status", unpaid: "created", owner_column: "user_id")
  end

  # ── Stuck-`paying` reconciliation ─────────────────────────────────────────
  #
  # A crash between a successful capture and the paid-flip leaves an order
  # `paying`: charged once, unpayable until reconciled. Each stuck order is
  # resolved against the best evidence there is:
  #
  #   • a settlement row ⇒ `paid`;
  #   • the processor, asked about every cart mandate that claimed the order:
  #     charged ⇒ `paid`, not charged ⇒ released to `created`;
  #   • no answer ⇒ UNRESOLVED, claim kept — releasing it invites the blind
  #     retry that charges twice.
  #
  # Called by `rake demo:reconcile`; `rake check:reconcile` asserts all three.
  #
  # @param lookup [#outcome] answers :paid / :not_charged / :unknown about one
  #   cart mandate. Required: a sweep must never reach a real processor by default.
  # @param older_than_seconds [Integer] claims younger than this may still be in flight
  # @return [Hash] { healed: [order_id, …], released: [order_id, …],
  #   unresolved: [{order_id:, claimed_at:, cart_mandate_ids:}, …] }
  def reconcile_stuck_paying!(lookup:, older_than_seconds: 900)
    orders = Order.arel_table
    stuck  = Order.where(status: Order::PAYING)
                  .where(orders[:updated_at].lt(Time.now.utc - older_than_seconds))
                  .order(:updated_at)
                  .pluck(:id, :updated_at)

    result = { healed: [], released: [], unresolved: [] }
    stuck.each do |id, updated_at|
      order_id = id.to_s
      case settled?(order_id) ? :paid : processor_says(order_id, lookup)
      when :paid
        heal!(order_id)
        result[:healed] << order_id
      when :not_charged
        release!(order_id)
        result[:released] << order_id
      else
        result[:unresolved] << { order_id: order_id, claimed_at: updated_at.to_s,
                                 cart_mandate_ids: cart_mandate_ids_for(order_id) }
      end
    end
    result
  end

  private

  def check_cart!(cart, order_id)
    products = Product.arel_table
    expected = OrderItem.joins(:product)
                        .where(order_id: order_id)
                        .pluck(products[:sku], :qty, products[:price_cents])
                        .map { |sku, qty, price_cents| [sku.to_s, qty.to_i, price_cents.to_i] }
                        .sort

    presented = Array(cart.line_items).reject { |li| li["order_id"] }.map do |li|
      sku   = li["sku"].to_s
      qty   = li["qty"].to_i
      price = li["price_cents"].to_i
      deny "each item line needs sku, qty, and price_cents (catalog price)" if sku.empty? || qty <= 0 || price <= 0
      [sku, qty, price]
    end.sort

    unless presented == expected
      deny "cart items do not mirror the order at catalog prices — re-read the catalog " \
           "and create_order's pay_hint"
    end

    line_sum    = presented.sum { |(_, qty, price)| qty * price }
    order_total = Order.where(id: order_id).pick(:total_cents).to_i
    return if cart.total_amount_cents.to_i == line_sum && line_sum == order_total

    deny "cart total #{cart.total_amount_cents} does not equal the order's catalog total #{order_total}"
  end

  # The basket is bought; from here the shop acts on its own clock.
  def paid!(order_id) = CourierDispatchJob.arm!(order_id)

  # A late payment found by the sweep: nobody is polling for it, so the owner
  # is told.
  def heal!(order_id)
    mark_paid!(order_id)
    owner_id = Order.where(id: order_id).pick(:user_id)
    return unless owner_id

    Kiosk::Server::Events.emit(
      topic: :order_payment, subject: order_id, identity_scope: [owner_id],
      data: { "order_id" => order_id, "payment_state" => "paid" },
    )
  end

  # ONE `:paid` settles it; `:not_charged` needs every mandate to say so, and an
  # order no mandate references stays `:unknown`.
  def processor_says(order_id, lookup)
    answers = Kiosk::CartMandate.referencing(order_id: order_id)
                                .pluck(:mandate_id, :total_amount_cents, :currency)
                                .map do |mandate_id, amount_cents, currency|
      lookup.outcome(cart_mandate_id: mandate_id.to_s, amount_cents: amount_cents, currency: currency)
    end

    return :paid        if answers.include?(:paid)
    return :not_charged if answers.any? && answers.all?(:not_charged)

    :unknown
  end

  # Persisted before the capture, so they exist when the settlement does not —
  # the handle for looking the charge up at the processor.
  def cart_mandate_ids_for(order_id)
    Kiosk::CartMandate.referencing(order_id: order_id).order(:created_at).pluck(:mandate_id).map(&:to_s)
  end
end
