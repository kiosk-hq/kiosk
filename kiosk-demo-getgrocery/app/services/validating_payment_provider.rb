# frozen_string_literal: true

# The cashier check, as a PSP-adapter decorator: before any capture, verify the
# agent-signed cart against the OPERATOR'S OWN catalog. The wire verifies the
# mandate chain's internal consistency (cart total == payment amount, one
# currency across the chain) but cannot know this shop's prices, so the operator
# counts what lands on the counter:
#
#   1. the cart is denominated in the operator's currency;
#   2. it references exactly one of the payer's own, not-yet-settled orders
#      (a {"order_id": ...} entry among line_items — see create_order's
#      pay_hint), by a well-formed uuid;
#   3. its item lines mirror that order exactly — same skus, same
#      quantities, prices as in the catalog at order time;
#   4. its total equals both the sum of those lines and the order's total.
#
# Any mismatch rejects the capture (403 — or 400 when the order reference is
# malformed rather than merely wrong); the mandate trail is persisted, nothing is
# charged.
#
# ── Per-order serialization (K-544) ───────────────────────────────────────
# The engine settles across two short DB transactions with the irreversible PSP
# capture BETWEEN them (executor P1→P2→P3), and the only "paid" marker is the
# settlement row written in P3, AFTER capture. That leaves two races open, both
# of which let a payer be charged for goods they did not sign:
#
#   (a) SWAP — while a /pay for order O is mid-capture, a concurrent
#       create_order{order_id:O, items:[expensive]} rewrites O's items+total,
#       and the settlement marks the now-expensive O paid though the cart only
#       charged the cheap total. Pay €1, get €500.
#   (b) DOUBLE CAPTURE — two /pay for the same O both read zero settlements and
#       both capture, charging twice under two idempotency keys.
#
# Both close by giving the order a tiny lifecycle — `created → paying → paid` —
# and CLAIMING it atomically before validating or charging, with one conditional
# `… WHERE status='created' RETURNING …` UPDATE: a row-locked, race-free
# compare-and-set. Once O is `paying`, a second /pay's claim matches zero rows
# (closes b) and create_order excludes `paying` under `FOR UPDATE` (closes a).
class ValidatingPaymentProvider
  def initialize(provider, currency:)
    @provider = provider
    @currency = currency.to_s.downcase
  end

  def capture(cart_mandate, payment_method: nil)
    order_id = claim_and_validate!(cart_mandate)
    begin
      settled = @provider.capture(cart_mandate, payment_method: payment_method)
    rescue StandardError => e
      release_claim_on_failure!(order_id, e)
      raise
    end
    # The engine's settlement row (executor P3) is the authoritative paid marker;
    # this local flip only keeps the status honest and rejects a later claim.
    mark_paid!(order_id)
    settled
  end

  def method_missing(name, *args, **kwargs, &block)
    @provider.public_send(name, *args, **kwargs, &block)
  end

  def respond_to_missing?(name, include_private = false)
    @provider.respond_to?(name, include_private) || super
  end

  # ── Stuck-`paying` reconciliation (K-578, LOCAL evidence only) ────────────
  #
  # A crash between a successful capture and the paid-flip leaves an order
  # `paying` forever: charged ONCE — the claim makes double-charging impossible —
  # but unpayable until something reconciles it. This sweep resolves what local
  # evidence can prove and REPORTS the rest instead of guessing:
  #
  #   • settlement row exists  ⇒ the charge is recorded; flip `paying` → `paid`.
  #   • no settlement row      ⇒ only the PSP knows whether money moved, so do
  #     NOT release the claim (that is exactly the blind retry K-545 forbids) and
  #     do NOT invent an answer; list the order UNRESOLVED with the cart-mandate
  #     ids to look up at the processor (the Stripe adapter stamps each
  #     PaymentIntent with `metadata.cart_mandate_id`).
  #
  # Callable from `rake demo:reconcile`. There is NO background worker in this
  # demo, and querying the PSP for the unresolved half is not built.
  #
  # THE THREE STATUS STATEMENTS here and in `claim_and_validate!` are RAW SQL
  # where every READ on this origin is a model call (K-654), because the claim's
  # ATOMICITY is the K-544/K-545 fix and `update_all` has no RETURNING in Rails
  # 8.1 — an ActiveRecord spelling would be a SELECT then an UPDATE, and the race
  # would be back. Every value still travels as a `$N` BIND rather than through
  # `conn.quote`: a demo is the file a provider copies, and the copy is where a
  # forgotten `quote` lives (`no_interpolated_sql_spec.rb` enforces it).
  #
  # @param older_than_seconds [Integer] ignore claims young enough to be a pay
  #   that is legitimately still in flight.
  # @return [Hash] { healed: [order_id, …], unresolved: [{order_id:, claimed_at:, cart_mandate_ids:}, …] }
  def self.reconcile_stuck_paying!(older_than_seconds: 900)
    orders = Order.arel_table
    stuck  = Order.where(status: Order::PAYING)
                  .where(orders[:updated_at].lt(Time.now.utc - older_than_seconds))
                  .order(:updated_at)
                  .pluck(:id, :updated_at)

    healed     = []
    unresolved = []

    stuck.each do |id, updated_at|
      order_id = id.to_s
      if settled?(order_id)
        Order.lease_connection.exec_update(
          "UPDATE orders SET status = 'paid', updated_at = now() " \
          "WHERE id = $1::uuid AND status = 'paying'",
          "getgrocery reconcile heal", [order_id]
        )
        healed << order_id
      else
        unresolved << {
          order_id:         order_id,
          claimed_at:       updated_at.to_s,
          cart_mandate_ids: cart_mandate_ids_for(order_id),
        }
      end
    end

    { healed: healed, unresolved: unresolved }
  end

  # True iff a settlement (capture receipt) references this order — the
  # authoritative local "this was charged" marker, written by executor phase 3.
  # {CartMandate.referencing} is ONE containment for the whole origin (K-654),
  # shared with `create_order`'s replace guard and `reschedule_delivery`'s
  # payment gate — and it matters most here, because THIS is the reader the K-545
  # race fix consults before deciding whether money has already moved.
  def self.settled?(order_id)
    Settlement.joins(:cart_mandate).merge(CartMandate.referencing(order_id)).exists?
  end

  # The agent-signed cart-mandate ids that referenced this order. Persisted
  # BEFORE the capture (executor phase 1), so they exist even when the settlement
  # does not — which makes them the handle for looking the charge up at the
  # processor (`metadata.cart_mandate_id`).
  def self.cart_mandate_ids_for(order_id)
    CartMandate.referencing(order_id).order(:created_at).pluck(:mandate_id).map(&:to_s)
  end

  private

  def settled?(order_id) = self.class.settled?(order_id)

  # Atomically claim the referenced order for payment, then run the cashier check
  # against it. Returns the order_id on success; raises Forbidden (403) on a
  # cashier rejection — reverting the claim first if it was taken — or BadRequest
  # (400) when the cart's order reference is not even a uuid, which is checked
  # before the claim so that there is nothing to revert.
  def claim_and_validate!(cart)
    unless cart.currency.to_s.downcase == @currency
      deny "cart currency #{cart.currency.inspect} rejected — this operator prices in " \
           "#{@currency.upcase} (the catalog carries a currency field)"
    end

    entries = Array(cart.line_items)
    refs    = entries.filter_map { |li| li["order_id"] }.map(&:to_s).uniq
    deny "cart line_items must reference exactly one order_id (see create_order's pay_hint)" unless refs.size == 1
    order_id = refs.first

    # K-579: the order_id goes straight into an `::uuid` cast below, where a
    # malformed one makes Postgres raise InvalidTextRepresentation — a raw 500,
    # and on the pay path a 500 is the worst answer there is, because an
    # assistant cannot tell "your input was wrong" from "the charge may have gone
    # through". So reject the SHAPE up front, with a 400 rather than the cashier's
    # 403: a malformed argument says nothing about whether any order exists.
    unless UuidCheck.valid?(order_id)
      raise Kiosk::Server::Errors::BadRequest.new(
        "cart line_items order_id #{order_id.inspect} is not a uuid",
        hint: "use the `order_id` create_order returned, verbatim (a canonical uuid, " \
              "e.g. 3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5b) — see its pay_hint",
      )
    end

    # CLAIM: created → paying, race-free compare-and-set. Winning this UPDATE is
    # what serializes concurrent /pay (only one can flip 'created') and, with
    # create_order's FOR UPDATE guard, freezes O's items for this payment
    # (K-544). `$1::uuid` casts the bound text, so a non-uuid is a Postgres
    # refusal rather than a silent miss.
    claimed = Order.lease_connection.exec_query(
      "UPDATE orders SET status = 'paying', updated_at = now() " \
      "WHERE id = $1::uuid " \
      "AND user_id = $2::uuid " \
      "AND status = 'created' " \
      "RETURNING id, total_cents",
      "getgrocery order claim", [order_id, cart.user_id.to_s]
    ).to_a.first

    if claimed.nil?
      # Distinguish "not yours / missing" from "not in a payable state" so the
      # assistant gets an actionable message instead of a bare 403. The payer
      # comes off the SIGNED mandate, never off a request argument.
      existing_status = Order.where(id: order_id, user_id: cart.user_id.to_s).pick(:status)
      deny "order not found or not yours" if existing_status.nil?

      # K-578 (local half): a `paying` order that ALREADY HAS a settlement is not
      # "in progress" — it was charged and only the local status flip was lost.
      # The settlement row is decisive local evidence, so heal the status here
      # rather than park the payer behind one that would never move.
      if existing_status == Order::PAYING && settled?(order_id)
        mark_paid!(order_id)
        deny "order already settled"
      end

      if existing_status == Order::PAYING
        # Claimed, no settlement: either a pay is genuinely in flight, or one
        # died at an UNKNOWN outcome and we deliberately kept the claim so a
        # blind retry can't double-charge (K-545). Say what recovers it.
        deny "order #{order_id} has a payment in progress — re-read GET <endpoint>/my_orders: " \
             "if it shows paid, the charge went through and there is nothing to retry; " \
             "if it stays unpaid, the operator must reconcile this order with the payment " \
             "processor before it can be paid again"
      end

      deny "order #{order_id} is not payable (status=#{existing_status}) — it may already be " \
           "paid, rescheduled, or otherwise past the payable state"
    end

    # Everything past the claim runs under the `paying` guard, so any rejection
    # must release it for a corrected retry to be possible.
    begin
      # Defense-in-depth: a settlement should never exist for an order still
      # 'created', but reject — and do not charge — if one somehow does.
      deny "order already settled" if settled?(order_id)

      products = Product.arel_table
      expected = OrderItem.joins(:product)
                          .where(order_id: order_id)
                          .pluck(products[:sku], :qty, products[:price_cents])
                          .map { |sku, qty, price_cents| [sku.to_s, qty.to_i, price_cents.to_i] }
                          .sort

      presented = entries.reject { |li| li["order_id"] }.map do |li|
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

      line_sum   = presented.sum { |(_, qty, price)| qty * price }
      order_total = claimed["total_cents"].to_i
      unless cart.total_amount_cents.to_i == line_sum && line_sum == order_total
        deny "cart total #{cart.total_amount_cents} does not equal the order's catalog total #{order_total}"
      end
    rescue StandardError
      release_claim!(order_id) # revert 'paying' → 'created'
      raise
    end

    order_id
  end

  # Release a claim we know involved NO charge (definitive decline / setup
  # required). On an UNKNOWN outcome, or any unexpected error, deliberately do
  # NOT release: leaving O `paying` blocks a blind retry that could double-charge
  # (K-545), and reconciliation resolves it out of band.
  def release_claim_on_failure!(order_id, error)
    return unless order_id

    safe = error.is_a?(Kiosk::PaymentProviders::SetupRequired) ||
           (error.is_a?(Kiosk::PaymentProviders::PaymentFailed) && error.retryable?)
    release_claim!(order_id) if safe
  end

  def release_claim!(order_id)
    set_status(order_id, from: "paying", to: "created")
  end

  def mark_paid!(order_id)
    set_status(order_id, from: "paying", to: "paid")
  rescue StandardError
    # The engine settlement (P3) already records the charge; a failed local flip
    # must never surface as an error over a paid order.
    nil
  end

  def set_status(order_id, from:, to:)
    Order.lease_connection.exec_update(
      "UPDATE orders SET status = $1, updated_at = now() " \
      "WHERE id = $2::uuid AND status = $3",
      "getgrocery order status flip", [to, order_id.to_s, from]
    )
  end

  def deny(message)
    raise Kiosk::Server::Errors::Forbidden.new(message)
  end
end
