# frozen_string_literal: true

# One basket, its delivery window and address. `timezone` is the clock of the
# delivery district the window was quoted on.
class Order < ApplicationRecord
  include Kiosk::Owned

  enum :status, {
    created:          "created",
    paying:           "paying",
    paid:             "paid",
    rescheduled:      "rescheduled",
    out_for_delivery: "out_for_delivery",
    delivered:        "delivered",
  }

  belongs_to :user
  has_many :order_items, dependent: :destroy

  # Paid and not yet with the courier.
  scope :awaiting_courier, -> { where(status: %i[paid rescheduled]) }
  # One move per order, and none once the courier has the basket.
  scope :reschedulable,    -> { where.not(status: %i[rescheduled out_for_delivery delivered]) }

  # A settlement whose cart names this order (`line_items @> [{order_id}]`).
  SETTLEMENT_FOR_ROW = Arel.sql(
    "kiosk.cart_mandates.line_items @> json_build_array(json_build_object('order_id', orders.id::text))::jsonb",
  ).freeze

  # Adds `settled` and `settled_currency`, read from the given settlements: the
  # caller's own on the wire, all of them in the back office.
  scope :with_settlement, lambda { |settlements|
    settlement = settlements.joins(:cart_mandate).where(SETTLEMENT_FOR_ROW)
    select(arel_table[Arel.star],
           Arel::Nodes::Exists.new(settlement.select(Arel.sql("1")).arel).as("settled"),
           Arel::Nodes::Grouping.new(settlement.select(:currency).limit(1).arel).as("settled_currency"))
  }

  def self.readable_by?(order_id, user_id) = where(id: order_id, user_id: user_id).exists?

  # What `my_orders` publishes about the money. `pending` means a capture is in
  # flight: the caller must reconcile, not sign a new mandate.
  def payment_state
    return "paid"    if paid? || settled
    return "pending" if paying?

    "unpaid"
  end

  def zone = Time.find_zone!(timezone)

  def items_by_product = order_items.sort_by { _1.product.name }
end
