# frozen_string_literal: true

# One basket, its delivery window and address. `timezone` is the clock of the
# delivery district the window was quoted on.
class Order < ApplicationRecord
  include Kiosk::Owned

  MAX_ITEMS = 50

  enum :status, {
    created: 'created',
    paying: 'paying',
    paid: 'paid',
    rescheduled: 'rescheduled',
    out_for_delivery: 'out_for_delivery',
    delivered: 'delivered',
    cancelled: 'cancelled'
  }

  belongs_to :user
  has_many :order_items, dependent: :destroy, autosave: true

  # What a caller placing or moving an order is held to.
  validates :order_items, length: { in: 1..MAX_ITEMS, too_short: 'must name a product',
                                    too_long: 'are at most %{count} lines' }, on: :place # rubocop:disable Style/FormatStringToken -- Rails I18n interpolates %{count}
  validates :address, served_address: true, on: %i[place reschedule]
  validate :window_bookable, on: %i[place reschedule]

  # Paid and not yet with the courier.
  AWAITING_COURIER = %w[paid rescheduled].freeze
  scope :awaiting_courier, -> { where(status: AWAITING_COURIER) }
  # One move per order, and none once the courier has the basket.
  scope :reschedulable,    -> { where.not(status: %i[rescheduled out_for_delivery delivered cancelled]) }

  # A settlement whose cart names this order (`line_items @> [{order_id}]`).
  SETTLEMENT_FOR_ROW = Arel.sql(
    "kiosk.cart_mandates.line_items @> json_build_array(json_build_object('order_id', orders.id::text))::jsonb"
  ).freeze

  # Adds `settled` and `settled_currency`, read from the given settlements: the
  # caller's own on the wire, all of them in the back office.
  scope :with_settlement, lambda { |settlements|
    settlement = settlements.joins(:cart_mandate).where(SETTLEMENT_FOR_ROW)
    select(arel_table[Arel.star],
           Arel::Nodes::Exists.new(settlement.select(Arel.sql('1')).arel).as('settled'),
           Arel::Nodes::Grouping.new(settlement.select(:currency).limit(1).arel).as('settled_currency'))
  }

  def self.readable_by?(order_id, user_id) = where(id: order_id, user_id: user_id).exists?

  # What `my_orders` publishes about the money. `pending` means a capture is in
  # flight: the caller must reconcile, not sign a new mandate.
  def payment_state
    return 'paid'    if paid? || settled
    return 'pending' if paying?

    'unpaid'
  end

  def zone = Time.find_zone!(timezone)

  def items_by_product = order_items.sort_by { it.product.name }

  # What the shelf cannot fill, e.g. ["milk-1l: Sold out. Check back tomorrow.", "banana: 3 ordered, 2 left"];
  # empty when it can.
  def shortfall
    order_items.group_by(&:product).filter_map do |product, items|
      qty = items.sum(&:qty)
      next if qty <= product.stock

      product.sold_out? ? "#{product.sku}: #{Product::SOLD_OUT}" : "#{product.sku}: #{qty} ordered, #{product.stock} left"
    end
  end

  # Once per paid order, whoever reports the payment first: the basket leaves
  # the shelf and the courier is booked. `dispatch_at` is NULL until then. A
  # line a concurrent payment emptied the shelf of is refunded; an order with
  # no line left is cancelled.
  def self.fulfil!(order_id)
    transaction do
      order = paid.where(dispatch_at: nil).lock.find_by(id: order_id)
      next unless order

      missing = order.order_items.sort_by(&:product_id).reject { Product.take!(it.product_id, it.qty).positive? }
      order.refund!(missing) if missing.any?
      CourierDispatchJob.arm!(order) unless order.cancelled?
    end
  end

  def refund!(lines)
    amount = lines.sum { it.price_cents * it.qty }
    Kiosk.configuration.payment_provider.refund(psp_reference: settled_reference, amount_cents: amount)
    update!(refunded_cents: amount, status: amount == total_cents ? :cancelled : status)
    announce_cancelled if cancelled?
  end

  # The order, for the one caller that moves the basket from the shop to the
  # courier; nil for any other.
  def hand_to_courier
    handed = self.class.where(id:, status: AWAITING_COURIER).update_all(status: 'out_for_delivery', updated_at: Time.current)
    tap { it.status = 'out_for_delivery' } if handed == 1
  end

  private

  def settled_reference
    Kiosk::Settlement.joins(:cart_mandate).merge(Kiosk::CartMandate.referencing(order_id: id)).pick(:psp_reference)
  end

  def announce_cancelled
    Kiosk::Server::Events.emit(
      topic: :order_delivery, subject: id, identity_scope: [user_id],
      data: { 'order_id' => id, 'status' => 'cancelled' }
    )
  end

  # A window takes orders while a basket paid now still reaches the door inside it.
  def window_bookable
    if slot_at.nil? || !DeliverySlots.start?(slot_at, zone)
      errors.add(:slot_at, 'must be the slot_at of a delivery_slots row')
    elsif DeliverySlots.closed?(slot_at)
      errors.add(:slot_at, "#{window_name} is no longer bookable; call delivery_slots for the open windows")
    end
  end

  # "08:00–10:00 (Europe/Dublin) on 2026-09-01".
  def window_name = "#{DeliverySlots.label(slot_at, zone)} on #{slot_at.in_time_zone(zone).to_date.iso8601}"
end
