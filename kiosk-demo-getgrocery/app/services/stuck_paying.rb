# frozen_string_literal: true

module StuckPaying
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
  # @param claim [Kiosk::Server::PaymentClaim] the claim the orders were paid under
  # @param lookup [#outcome] answers :paid / :not_charged / :unknown about one
  #   cart mandate. Required: a sweep must never reach a real processor by default.
  # @param older_than_seconds [Integer] claims younger than this may still be in flight
  # @return [Hash] { healed: [order_id, …], released: [order_id, …],
  #   unresolved: [{order_id:, claimed_at:, cart_mandate_ids:}, …] }
  def self.reconcile!(lookup:, older_than_seconds: 900, claim: Kiosk.configuration.payment_provider)
    orders = Order.arel_table
    stuck  = Order.where(status: Order::PAYING)
                  .where(orders[:updated_at].lt(Time.now.utc - older_than_seconds))
                  .order(:updated_at)
                  .pluck(:id, :updated_at)

    result = { healed: [], released: [], unresolved: [] }
    stuck.each do |id, updated_at|
      order_id = id.to_s
      case claim.settled?(order_id) ? :paid : processor_says(order_id, lookup)
      when :paid
        heal!(claim, order_id)
        result[:healed] << order_id
      when :not_charged
        claim.release!(order_id)
        result[:released] << order_id
      else
        result[:unresolved] << { order_id: order_id, claimed_at: updated_at.to_s,
                                 cart_mandate_ids: cart_mandate_ids_for(order_id) }
      end
    end
    result
  end

  # A late payment found by the sweep: nobody is polling for it, so the owner
  # is told.
  def self.heal!(claim, order_id)
    claim.mark_paid!(order_id)
    owner_id = Order.where(id: order_id).pick(:user_id)
    return unless owner_id

    Kiosk::Server::Events.emit(
      topic: :order_payment, subject: order_id, identity_scope: [owner_id],
      data: { "order_id" => order_id, "payment_state" => "paid" },
    )
  end

  # ONE `:paid` settles it; `:not_charged` needs every mandate to say so, and an
  # order no mandate references stays `:unknown`.
  def self.processor_says(order_id, lookup)
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
  def self.cart_mandate_ids_for(order_id)
    Kiosk::CartMandate.referencing(order_id: order_id).order(:created_at).pluck(:mandate_id).map(&:to_s)
  end
end
