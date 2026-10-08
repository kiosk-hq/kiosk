# frozen_string_literal: true

module Admin
  module OrdersHelper
    CURRENCY_GLYPHS = { "usd" => "$", "gbp" => "£", "eur" => "€" }.freeze

    # The shop's own states outrank the settlement: a delivered basket is also paid.
    STATUS_BADGES = { "delivered" => "delivered", "out_for_delivery" => "out-for-delivery",
                      "rescheduled" => "scheduled" }.freeze

    def order_badge(order)
      badge = STATUS_BADGES.fetch(order.status) { order.settled_currency ? "paid" : "created" }
      tag.span(badge.tr("-", " ").upcase, class: "badge badge-#{badge}")
    end

    # An amount in the currency the order settled in; € until it has settled.
    def order_money(order, cents)
      format("%s%.2f", CURRENCY_GLYPHS.fetch(order.settled_currency.to_s.downcase, "€"), cents / 100.0)
    end

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
