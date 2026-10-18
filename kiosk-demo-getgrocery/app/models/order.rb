# frozen_string_literal: true

# One basket, its delivery window and address. `timezone` is the clock of the
# delivery district the window was quoted on.
class Order < ApplicationRecord
  include Kiosk::Owned
  include Kiosk::Payable

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
  scope :awaiting_courier, -> { paid.or(rescheduled) }
  # One move per order, and none once the courier has the basket.
  scope :reschedulable,    -> { not_rescheduled.not_out_for_delivery.not_delivered.not_cancelled }

  def self.readable_by?(order_id, user_id) = exists?(id: order_id, user_id: user_id)

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

      missing = order.order_items.sort_by(&:product_id).reject { Product.take!(it.product_id, it.qty) }
      order.refund!(missing) if missing.any?
      CourierDispatchJob.arm!(order) unless order.cancelled?
    end
  end

  def refund!(lines)
    amount = lines.sum { it.price_cents * it.qty }
    Kiosk.configuration.payment_provider.refund(psp_reference: settlement.psp_reference, amount_cents: amount)
    update!(refunded_cents: amount, status: amount == total_cents ? :cancelled : status)
    announce_cancelled if cancelled?
  end

  def awaiting_courier? = paid? || rescheduled?

  # Moves the basket from the shop to the courier. The row lock makes two runs
  # take turns; false for the run that finds the courier already has it.
  def hand_to_courier!
    with_lock { awaiting_courier? && out_for_delivery! }
  end

  private

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
