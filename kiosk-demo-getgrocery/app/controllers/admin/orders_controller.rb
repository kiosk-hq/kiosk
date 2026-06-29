# frozen_string_literal: true

module Admin
  # Read-only orders view for the store operator — shows recent deliveries with
  # payment status, address, slot, and line items (substitutions flagged).
  #
  # NOTE: No authentication is required here — this is a *demo* provider.
  # Production would authenticate the operator before serving this page, e.g.:
  #   • Devise admin role + before_action :authenticate_admin!
  #   • HTTP Basic Auth via `http_basic_authenticate_with`
  #   • mTLS client certificate + IP allowlist
  class OrdersController < ActionController::Base
    layout false

    def index
      @orders = load_orders
    end

    private

    def load_orders
      conn = ActiveRecord::Base.connection

      deliveries = conn.execute(<<~SQL).to_a
        SELECT
          d.id,
          LEFT(d.id::text, 8) AS short_id,
          d.slot_at,
          d.address,
          d.status,
          d.created_at,
          d.cart_id,
          COALESCE((
            SELECT TRUE
            FROM kiosk.cart_mandates cm
            JOIN kiosk.payment_mandates pm ON pm.cart_mandate_id = cm.id
            WHERE cm.line_items @> json_build_array(
              json_build_object('delivery_id', d.id::text)
            )::jsonb
            LIMIT 1
          ), FALSE) AS paid
        FROM deliveries d
        ORDER BY d.created_at DESC
        LIMIT 50
      SQL

      return [] if deliveries.empty?

      # Collect UUIDs (already from DB, validated format for safety)
      cart_ids = deliveries.map { |d| d["cart_id"] }.compact.uniq
                           .select { |id| id.to_s.match?(/\A[0-9a-f\-]{36}\z/i) }

      items_by_cart = {}
      unless cart_ids.empty?
        quoted_ids = cart_ids.map { |id| conn.quote(id) }.join(", ")
        conn.execute(<<~SQL).each { |r| (items_by_cart[r["cart_id"]] ||= []) << r }
          SELECT
            ci.cart_id::text AS cart_id,
            ci.qty,
            ci.substituted,
            p.name AS product_name,
            p.price_cents
          FROM cart_items ci
          JOIN products p ON p.id = ci.product_id
          WHERE ci.cart_id::text IN (#{quoted_ids})
          ORDER BY p.name ASC
        SQL
      end

      deliveries.map { |d| d.merge("items" => (items_by_cart[d["cart_id"]] || [])) }
    end
  end
end
