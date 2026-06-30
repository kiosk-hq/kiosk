# frozen_string_literal: true

module Admin
  # Read-only orders view for the GetGroceries provider operator.
  # Shows recent orders with payment status, address, slot, and line items.
  #
  # NOTE: No authentication — demo provider only.
  class OrdersController < ActionController::Base
    layout false

    def index
      @orders = load_orders
    end

    private

    def load_orders
      conn = ActiveRecord::Base.connection

      orders = conn.execute(<<~SQL).to_a
        SELECT
          o.id,
          LEFT(o.id::text, 8)           AS short_id,
          o.status,
          o.total_cents,
          o.slot_at,
          o.address,
          o.created_at,
          COALESCE((
            SELECT TRUE
            FROM kiosk.cart_mandates cm
            JOIN kiosk.settlements pm ON pm.cart_mandate_id = cm.id
            WHERE cm.line_items @> json_build_array(
              json_build_object('order_id', o.id::text)
            )::jsonb
            LIMIT 1
          ), FALSE) AS paid
        FROM orders o
        ORDER BY o.created_at DESC
        LIMIT 50
      SQL

      return [] if orders.empty?

      order_ids = orders.map { |o| o["id"] }.compact.uniq
                        .select { |id| id.to_s.match?(/\A[0-9a-f\-]{36}\z/i) }

      items_by_order = {}
      unless order_ids.empty?
        quoted_ids = order_ids.map { |id| conn.quote(id) }.join(", ")
        conn.execute(<<~SQL).each { |r| (items_by_order[r["order_id"]] ||= []) << r }
          SELECT
            oi.order_id::text AS order_id,
            oi.qty,
            p.name            AS product_name,
            p.price_cents
          FROM order_items oi
          JOIN products p ON p.id = oi.product_id
          WHERE oi.order_id::text IN (#{quoted_ids})
          ORDER BY p.name ASC
        SQL
      end

      orders.map { |o| o.merge("items" => (items_by_order[o["id"]] || [])) }
    end
  end
end
