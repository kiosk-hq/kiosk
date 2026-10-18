# frozen_string_literal: true

module Admin
  module OrdersHelper
    # The basket's own states outrank the money: a delivered basket is also paid.
    STATUS_BADGES = { 'delivered' => 'delivered', 'out_for_delivery' => 'out-for-delivery',
                      'rescheduled' => 'scheduled' }.freeze
    # Any other order wears the state of its money, its `payment_state`.
    PAYMENT_BADGES = { Kiosk::Payable::UNPAID => 'created', Kiosk::Payable::PENDING => 'pending',
                       Kiosk::Payable::PAID => 'paid', Kiosk::Payable::REFUNDED => 'refunded' }.freeze

    def order_badge(order)
      badge = STATUS_BADGES.fetch(order.status) { PAYMENT_BADGES.fetch(order.payment_state) }
      tag.span(badge.tr('-', ' ').upcase, class: "badge badge-#{badge}")
    end

    # The shop charges in euro.
    def order_money(cents) = number_to_currency(cents / 100.0, unit: '€')

    # The delivery window on the order's own clock, worded as the wire words it.
    def order_slot(order)
      "#{order.slot_at.in_time_zone(order.zone).strftime('%a %-d %b')}, " \
        "#{DeliverySlots.label(order.slot_at, order.zone)}"
    end

    def order_placed_at(order)
      "#{order.created_at.in_time_zone(order.zone).strftime('%-d %b %Y at %H:%M')} (#{order.zone.name})"
    end

    # A visitor-typed address with all but a short head and tail masked.
    def masked_address(address)
      return address if address.length <= 7

      "#{address[0, 4]}#{'*' * (address.length - 7).clamp(3, 18)}#{address[-3, 3]}"
    end
  end
end
