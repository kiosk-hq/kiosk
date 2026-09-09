# frozen_string_literal: true

module Admin
  # Read-only orders view for the GetGrocery provider operator.
  # Shows recent orders with payment status, address, slot, and line items.
  #
  # THE SECOND SURFACE, and the reason it borrows the wire's containment rather
  # than writing its own. "Is this order paid" is a fact BOTH an assistant and
  # the operator ask for, and two hand-written SQL strings — the same jsonb
  # containment over kiosk.settlements → kiosk.cart_mandates, spelled twice —
  # would be free to drift apart.
  # It is {Order.settling}, once, and each surface hands it the settlements
  # it is entitled to read: the wire passes `Settlement.of_current_principal`, so
  # an assistant learns only its own orders' paid state; this page passes
  # `Settlement.all`, because a back office that could see one principal's
  # settlements would show every order unpaid. The AUTHORITY differs and must;
  # the CONTAINMENT does not, and cannot any more.
  #
  # NOTE: No authentication — public by design: an operator-view showcase on a
  # sandbox with synthetic data. Delivery addresses are visitor-typed free
  # text, so they are masked server-side to a short head + tail.
  #
  # No-coverage rationale: this is a pure
  # human-inspection back-office view, not a wire/spec surface. It is reachable
  # only via GET /admin/orders (routes.rb) and called by no flow driver, redteam
  # scenario, or Kiosk verb — it exists solely so an operator can eyeball orders
  # after demo:shop. The demo ships no controller-test harness (its assertions
  # are the booted-server flow drivers, Postgres-gated); the underlying read
  # correctness — paid-status via kiosk.settlements→cart_mandates and the items
  # join — is already exercised end-to-end by demo:shop (settlement + order_items
  # row-count assertions) and demo:isolation, and since the containment is now
  # shared with `my_orders`, those gates cover this page's half of it too.
  # Adding a booted-server assertion for this visualization surface alone would be
  # disproportionate, so it is left documented-uncovered rather than asserted.
  class OrdersController < ActionController::Base
    layout false

    RECENT = 50

    def index
      @orders = load_orders
    end

    private

    def load_orders
      # `Settlement.all`: the operator sees every principal's receipts. This page
      # runs OUTSIDE the wire, so no `SET LOCAL` GUC has been issued and
      # `kiosk.current_user_id()` would be NULL — which is exactly why the
      # principal scope is a PARAMETER of the shared seam rather than baked into
      # it. The `settled_currency` scalar drives the glyph in the view, and its
      # presence IS the paid flag: an unpaid order has no settlement to read a
      # currency from.
      orders = Order.order(created_at: :desc)
                    .limit(RECENT)
                    .pluck(:id, :status, :total_cents, :slot_at, :address, :created_at,
                           Order.settled_currency(Settlement.all))
      return [] if orders.empty?

      # The raw version filtered these ids through a uuid regex before
      # interpolating them into an `IN (…)` list. They are this table's own
      # primary keys and were never caller-supplied; the filter was defending the
      # string-building, and the string-building is gone.
      products = Product.arel_table
      items_by_order = OrderItem.joins(:product)
                                .where(order_id: orders.map(&:first))
                                .order(products[:name].asc)
                                .pluck(:order_id, :qty, products[:name], products[:price_cents])
                                .group_by(&:first)

      orders.map do |id, status, total_cents, slot_at, address, created_at, settled_currency|
        # The clock this ORDER's times are said out loud on: the delivery
        # address's, resolved through the same routing that chose its district
        # when it was placed. Two orders on one screen may be on two clocks, and
        # each label names its own.
        order_zone = DeliverySlots.zone_for(DublinZones.extract_district(address))
        { "id"               => id,
          "short_id"         => id.to_s[0, 8],
          "status"           => status,
          "total_cents"      => total_cents,
          # THE WINDOW IS RENDERED HERE, THROUGH THE ONE WRITER THE WIRE USES.
          # `slot_at` is a `timestamptz` and ActiveRecord hands it back as a
          # TimeWithZone in `Time.zone` — UTC here, because this app sets no
          # `config.time_zone` — so a view that re-parsed
          # it would print 07:00 where the customer was told
          # «08:00–10:00 (Europe/Dublin)». {DeliverySlots.label} is the single
          # writer for that string and {DeliverySlots.zone_for} for the day
          # beside it, so the shop's own staff and the assistant read ONE answer
          # about ONE window. The clock is the DELIVERY ADDRESS's, resolved from
          # the order's own address through the same routing that chose the
          # district when it was placed. The raw instant stays in the row for
          # anything that needs the value rather than the sentence.
          "slot_at"          => slot_at,
          "slot_window"      => slot_at && "#{slot_at.in_time_zone(order_zone).strftime('%a %-d %b')}, " \
                                           "#{DeliverySlots.label(slot_at, order_zone)}",
          "created_at"       => created_at,
          # AND THE ORDER'S OWN TIMESTAMP IS ON THE SAME CLOCK. A Dublin
          # delivery window beside an «Ordered» time on the server's clock, with
          # nothing on the page saying which is which, is worse for the operator
          # than two wrong times that at least agree.
          # `created_at` is a `timestamptz` and arrives in `Time.zone` for the
          # same reason `slot_at` does, so it is read
          # through the SAME zone and NAMES it, exactly as {DeliverySlots.label}
          # names it for the window. One screen, one clock, both of them said out
          # loud.
          "created_label"    => created_at && "#{created_at.in_time_zone(order_zone).strftime('%-d %b %Y at %H:%M')} " \
                                              "(#{order_zone.name})",
          "settled_currency" => settled_currency,
          "items"            => (items_by_order[id] || []).map { |_order_id, qty, name, price_cents|
            { "qty" => qty, "product_name" => name, "price_cents" => price_cents }
          },
          "paid"             => !settled_currency.nil?,
          "address"          => mask_address(address) }
      end
    end

    # All but a short head and tail of the visitor-typed address, masked.
    def mask_address(addr)
      s = addr.to_s
      return s if s.length <= 7
      "#{s[0, 4]}#{"*" * [[s.length - 7, 3].max, 18].min}#{s[-3, 3]}"
    end
  end
end
