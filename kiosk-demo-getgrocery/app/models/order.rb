# frozen_string_literal: true

# One basket, its delivery window and address. `status` is the basket,
# `payment_status` the money. `timezone` is the clock of the delivery district
# the window was quoted on.
class Order < ApplicationRecord
  include Kiosk::Owned
  include Kiosk::Payable

  MAX_ITEMS = 50

  enum :status, {
    placed: 'placed',
    rescheduled: 'rescheduled',
    out_for_delivery: 'out_for_delivery',
    delivered: 'delivered',
    cancelled: 'cancelled'
  }
  enum :payment_status, { unpaid: 'unpaid', paying: 'paying', paid: 'paid', refunded: 'refunded' }

  belongs_to :user
  has_many :order_items, dependent: :destroy, autosave: true

  # What a caller placing or moving an order is held to.
  validates :order_items, length: { in: 1..MAX_ITEMS, too_short: 'must name a product',
                                    too_long: 'are at most %{count} lines' }, on: :place # rubocop:disable Style/FormatStringToken -- Rails I18n interpolates %{count}
  validates :address, served_address: true, on: %i[place reschedule]
  validate :window_bookable, on: %i[place reschedule]

  # Paid and not yet with the courier.
  scope :awaiting_courier, -> { paid.where(status: %i[placed rescheduled]) }
  # One move per order, and none once the courier has the basket.
  scope :reschedulable,    -> { placed }

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

  def awaiting_courier? = paid? && (placed? || rescheduled?)

  # Moves the basket from the shop to the courier. The row lock makes two runs
  # take turns; false for the run that finds the courier already has it.
  def hand_to_courier!
    with_lock { awaiting_courier? && out_for_delivery! }
  end

  private

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
