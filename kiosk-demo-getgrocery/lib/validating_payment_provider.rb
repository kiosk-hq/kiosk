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
#      pay_hint), by a well-formed uuid;
#   3. its item lines mirror that order exactly — same skus, same
#      quantities, prices as in the catalog at order time;
#   4. its total equals both the sum of those lines and the order's total.
#
# Any mismatch rejects the capture (403 — or 400 when the order reference is
# malformed rather than merely wrong); the mandate trail is persisted, nothing
# is charged.
#
# ── Per-order serialization (K-544) ───────────────────────────────────────
# The engine settles between two short DB transactions with the irreversible
# PSP capture BETWEEN them (executor P1→P2→P3), and the only "paid" marker is
# the settlement row written in P3, AFTER capture. On its own that leaves two
# races open, both of which let a payer be charged for goods they did not sign:
#
#   (a) SWAP — while a /pay for order O is mid-capture, a concurrent
#       create_order{order_id:O, items:[expensive]} rewrites O's items+total;
#       the settlement then marks the now-expensive O paid though the cart only
#       proved (and only charged) the cheap total. Pay €1, get €500.
#   (b) DOUBLE CAPTURE — two /pay for the same O (two distinct carts) both read
#       zero settlements and both capture, charging twice under two idempotency
#       keys.
#
# We close both by giving the order a tiny lifecycle and CLAIMING it atomically
# before validating/charging: `created → paying → paid`. The claim is a single
# conditional UPDATE (`… WHERE status='created' RETURNING …`) — a row-locked,
# race-free compare-and-set. Once O is `paying`:
#   • a second /pay's claim matches zero rows → rejected (closes b);
#   • create_order excludes `paying` under `FOR UPDATE`, so it can't mutate O
#     while a pay is in flight (closes a).
# On a definitive decline / no-charge failure we release `paying → created` so
# the human can retry; on an UNKNOWN outcome (timeout) we deliberately LEAVE it
# `paying` so a blind retry can't double-charge (K-545). On success we flip
# `paying → paid`.
class ValidatingPaymentProvider
  # Canonical 8-4-4-4-12 hex uuid — the shape `create_order` returns and stamps
  # into its `pay_hint`. The cart's `order_id` is agent-supplied and reaches
  # Postgres as `…::uuid` in every statement below, so its shape is checked
  # BEFORE any SQL (K-579): a malformed value made Postgres raise
  # InvalidTextRepresentation (SQLSTATE 22P02), which is not a
  # Kiosk::Server::Errors::Base and so escaped the wire controller's rescue as an
  # HTTP 500 — the same 500-not-4xx class the engine closed in K-551. Postgres
  # would also accept a few non-canonical spellings (brace-wrapped, un-hyphenated);
  # we deliberately require the canonical form the operator itself hands out, so
  # the rejection message can name exactly what to send.
  ORDER_ID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def initialize(provider, currency:)
    @provider = provider
    @currency = currency.to_s.downcase
  end

  def capture(cart_mandate, payment_method: nil)
    order_id = claim_and_validate!(cart_mandate)
    begin
      settled = @provider.capture(cart_mandate, payment_method: payment_method)
    rescue StandardError => e
      # Release the claim ONLY when we know no money moved (a definitive decline
      # or a pre-charge SetupRequired). On an UNKNOWN outcome we keep O `paying`
      # so a lost-response retry is rejected rather than double-charging (K-545).
      release_claim_on_failure!(order_id, e)
      raise
    end
    # Charge succeeded — mark O terminally paid. The engine's settlement row
    # (executor P3) is the authoritative paid marker; this local flip is for an
    # honest status + to reject any later claim, so a failure here must NOT
    # undo a successful charge — swallow it and let P3 record the settlement.
    mark_paid!(order_id)
    settled
  end

  def method_missing(name, *args, **kwargs, &block)
    @provider.public_send(name, *args, **kwargs, &block)
  end

  def respond_to_missing?(name, include_private = false)
    @provider.respond_to?(name, include_private) || super
  end

  private

  # Atomically claim the referenced order for payment, then run the cashier
  # check against it. Returns the order_id (String) on success; raises
  # Forbidden (403) on a cashier rejection — reverting the claim first if it was
  # taken — or BadRequest (400) when the cart's order reference is not even a
  # uuid (checked before the claim, so there is nothing to revert).
  def claim_and_validate!(cart)
    unless cart.currency.to_s.downcase == @currency
      deny "cart currency #{cart.currency.inspect} rejected — this operator prices in " \
           "#{@currency.upcase} (the catalog carries a currency field)"
    end

    entries = Array(cart.line_items)
    refs    = entries.filter_map { |li| li["order_id"] || li[:order_id] }.map(&:to_s).uniq
    deny "cart line_items must reference exactly one order_id (see create_order's pay_hint)" unless refs.size == 1
    order_id = refs.first

    # K-579: shape-check the agent-supplied reference BEFORE it reaches the
    # `::uuid` casts below — a malformed one 500s inside Postgres instead of
    # answering the agent. A 400 (not the cashier's 403): this is a malformed
    # argument, not a refusal to serve a well-formed one, and it says nothing
    # about whether any order exists. The message echoes only the value the
    # agent itself sent — no SQL, no PG error text.
    unless ORDER_ID_FORMAT.match?(order_id)
      raise Kiosk::Server::Errors::BadRequest.new(
        "cart line_items order_id #{order_id.inspect} is not a uuid",
        hint: "use the order_id create_order returned verbatim (canonical uuid, " \
              "e.g. 3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5b) — see its pay_hint",
      )
    end

    conn = ActiveRecord::Base.connection

    # CLAIM: created → paying, race-free compare-and-set. Winning this UPDATE is
    # what serializes concurrent /pay (only one can flip 'created') and, together
    # with create_order's FOR UPDATE guard, freezes O's items for the duration of
    # this payment (K-544).
    claimed = conn.execute(
      "UPDATE orders SET status = 'paying', updated_at = now() " \
      "WHERE id = #{conn.quote(order_id)}::uuid " \
      "AND user_id = #{conn.quote(cart.user_id.to_s)}::uuid " \
      "AND status = 'created' " \
      "RETURNING id, total_cents"
    ).first

    if claimed.nil?
      # Distinguish "not yours / missing" from "not in a payable state" so the
      # assistant gets an actionable message instead of a bare 403.
      existing = conn.execute(
        "SELECT status FROM orders " \
        "WHERE id = #{conn.quote(order_id)}::uuid " \
        "AND user_id = #{conn.quote(cart.user_id.to_s)}::uuid LIMIT 1"
      ).first
      deny "order not found or not yours" if existing.nil?
      deny "order #{order_id} is not payable (status=#{existing["status"]}) — it may already be " \
           "paid, or a payment for it is already in progress"
    end

    # Everything past the claim runs under the `paying` guard; any rejection
    # must release it (revert to 'created') so a corrected retry can proceed.
    begin
      # Defense-in-depth: a settlement should never exist for an order that was
      # still 'created', but reject (and don't charge) if one somehow does.
      settled_filter = [{ order_id: order_id }].to_json
      already = conn.execute(
        "SELECT 1 AS ok FROM kiosk.settlements pm " \
        "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
        "WHERE cm.line_items @> #{conn.quote(settled_filter)}::jsonb LIMIT 1"
      ).first
      deny "order already settled" unless already.nil?

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
  # required). On an UNKNOWN capture outcome (non-retryable PaymentFailed) or any
  # other unexpected error we deliberately do NOT release — leaving O `paying`
  # blocks a blind retry that could double-charge (K-545); reconciliation
  # resolves it out of band.
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
    # A successful charge is already recorded by the engine settlement (P3); a
    # failed local status flip must never surface as an error over a paid order.
    nil
  end

  def set_status(order_id, from:, to:)
    conn = ActiveRecord::Base.connection
    conn.execute(
      "UPDATE orders SET status = #{conn.quote(to)}, updated_at = now() " \
      "WHERE id = #{conn.quote(order_id.to_s)}::uuid AND status = #{conn.quote(from)}"
    )
  end

  def deny(message)
    raise Kiosk::Server::Errors::Forbidden.new(message)
  end
end
