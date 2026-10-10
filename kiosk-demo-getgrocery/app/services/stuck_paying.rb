# frozen_string_literal: true

module StuckPaying
  # Resolves orders left `paying` by a crash between capture and the paid flip:
  # a settlement or a processor charge makes them paid, a processor that charged
  # nothing releases them, and no answer leaves the claim in place.
  #
  # @param lookup [#outcome] answers :paid, :not_charged or :unknown for a cart mandate
  def self.reconcile!(lookup:, older_than_seconds: 900)
    claim  = Kiosk.configuration.payment_provider
    orders = Order.arel_table
    stuck  = Order.paying
                  .where(orders[:updated_at].lt(older_than_seconds.seconds.ago))
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

  # Nobody is polling for a late payment, so the owner is told.
  def self.heal!(claim, order_id)
    claim.mark_paid!(order_id)
    owner_id = Order.where(id: order_id).pick(:user_id)
    return unless owner_id

    Kiosk::Server::Events.emit(
      topic: :order_payment, subject: order_id, identity_scope: [owner_id],
      data: { "order_id" => order_id, "payment_state" => "paid" },
    )
  end

  # One `:paid` settles it; `:not_charged` needs every mandate to say so.
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

  def self.cart_mandate_ids_for(order_id)
    Kiosk::CartMandate.referencing(order_id: order_id).order(:created_at).pluck(:mandate_id).map(&:to_s)
  end
end
