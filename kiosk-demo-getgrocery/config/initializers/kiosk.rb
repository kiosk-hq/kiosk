# frozen_string_literal: true

# Kiosk-demo (getgrocery-shape) configuration.
# Single grocery provider — no store layer. Catalog exposes in-stock facts;
# the AI assistant handles substitution decisions.
# Queries: catalog, delivery_slots, my_orders
# Actions: create_order, schedule_delivery

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")

ActiveRecord::Migration.include(Kiosk::RLS::DSL)

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3005")
  c.roles  = %i[customer]
  c.owner  = { name: "getgrocery", support: "help@getgrocery.app" }

  c.agent_idp        = JwtOrStubIdp.new(stub: StubIdp.new)
  c.payment_provider = StubPsp.new
end

LOW_STOCK_THRESHOLD = 5

# ─── Queries ────────────────────────────────────────────────────────────────

Kiosk::Server::Queries.register("catalog",
  description: "Browse in-stock products from the getgrocery catalog (out-of-stock items are hidden)") do |_params|
  conn = ActiveRecord::Base.connection
  rows = conn.execute(
    "SELECT id, name, price_cents, stock FROM products WHERE stock > 0 ORDER BY name"
  ).to_a
  rows.map do |r|
    row = { "id" => r["id"], "name" => r["name"], "price_cents" => r["price_cents"] }
    row["low"] = true if r["stock"].to_i <= LOW_STOCK_THRESHOLD
    row
  end
end

Kiosk::Server::Queries.register("delivery_slots",
  description: "Get available delivery time slots for a given date",
  params: {
    date: "date string YYYY-MM-DD — desired delivery date",
  }) do |params|
  date = params.fetch(:date) { raise Kiosk::Server::Errors::BadRequest.new("missing param: date") }

  parsed = begin
    Date.parse(date.to_s)
  rescue ArgumentError
    raise Kiosk::Server::Errors::BadRequest.new("invalid date: #{date}")
  end

  (0..5).map do |i|
    hour = 8 + i * 2
    slot_time = Time.utc(parsed.year, parsed.month, parsed.day, hour, 0, 0)
    {
      "id"      => i + 1,
      "slot_at" => slot_time.iso8601,
      "label"   => "#{hour.to_s.rjust(2, "0")}:00–#{(hour + 2).to_s.rjust(2, "0")}:00",
    }
  end
end

Kiosk::Server::Queries.register("my_orders",
  description: "List this principal's orders (scoped to authenticated user via kiosk.current_user_id())") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, status, total_cents, slot_at, address " \
    "FROM orders " \
    "WHERE user_id = kiosk.current_user_id() " \
    "ORDER BY created_at DESC"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

Kiosk::Server::Actions.register("create_order",
  description: "Create (or replace) a grocery order for the authenticated principal",
  params: {
    items:    "array of {product_id, qty} — the complete cart",
    order_id: "(optional) uuid — if given and order belongs to principal and not yet paid, replaces its items",
  }) do |args|
  conn = ActiveRecord::Base.connection
  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  items = args[:items] || args["items"] || []
  raise Kiosk::Server::Errors::BadRequest.new("items must be a non-empty array") if items.empty?

  items = items.map do |it|
    product_id = (it[:product_id] || it["product_id"]).to_i
    qty        = (it[:qty]        || it["qty"] || 1).to_i
    raise Kiosk::Server::Errors::BadRequest.new("qty must be >= 1") if qty < 1
    { product_id: product_id, qty: qty }
  end

  product_ids = items.map { |i| i[:product_id] }

  conn.transaction do
    # Compute total from current prices
    quoted_ids = product_ids.map { |id| conn.quote(id.to_s) }.join(", ")
    price_rows = conn.execute(
      "SELECT id, price_cents FROM products WHERE id IN (#{quoted_ids})"
    ).to_a
    price_map = price_rows.each_with_object({}) { |r, h| h[r["id"].to_i] = r["price_cents"].to_i }

    total_cents = items.sum { |i| (price_map[i[:product_id]] || 0) * i[:qty] }

    # Optional order_id: replace items if order belongs to principal and is not yet paid/scheduled
    given_order_id = args[:order_id] || args["order_id"]
    order_id = nil

    if given_order_id && !given_order_id.to_s.empty?
      existing = conn.execute(
        "SELECT id, status FROM orders " \
        "WHERE id = #{conn.quote(given_order_id.to_s)}::uuid " \
        "AND user_id = #{conn.quote(uid)}::uuid " \
        "AND status NOT IN ('paid', 'scheduled') " \
        "LIMIT 1"
      ).first

      if existing
        order_id = existing["id"]
        # Replace items
        conn.execute("DELETE FROM order_items WHERE order_id = #{conn.quote(order_id.to_s)}::uuid")
        conn.execute(
          "UPDATE orders SET total_cents = #{conn.quote(total_cents)}, updated_at = now() " \
          "WHERE id = #{conn.quote(order_id.to_s)}::uuid"
        )
      end
    end

    unless order_id
      # Create new order
      order_id = conn.execute(
        "INSERT INTO orders (id, user_id, status, total_cents, created_at, updated_at) " \
        "VALUES (gen_random_uuid(), #{conn.quote(uid)}::uuid, 'created', #{conn.quote(total_cents)}, now(), now()) " \
        "RETURNING id"
      ).first["id"]
    end

    # Insert order_items
    items.each do |item|
      conn.execute(
        "INSERT INTO order_items (order_id, product_id, qty, created_at, updated_at) " \
        "VALUES (#{conn.quote(order_id.to_s)}::uuid, #{conn.quote(item[:product_id].to_s)}::integer, " \
        "#{conn.quote(item[:qty].to_s)}::integer, now(), now())"
      )
    end

    { order_id: order_id, total_cents: total_cents }
  end
end

Kiosk::Server::Actions.register("schedule_delivery",
  description: "Schedule delivery for a paid order (requires settled payment mandate referencing this order)",
  params: {
    order_id:         "uuid — the order to schedule",
    delivery_slot_id: "integer — slot id from the delivery_slots query (1–6)",
    delivery_address: "string — delivery address",
  }) do |args|
  conn = ActiveRecord::Base.connection

  order_id         = args[:order_id]         || args["order_id"]
  delivery_slot_id = args[:delivery_slot_id] || args["delivery_slot_id"]
  delivery_address = args[:delivery_address] || args["delivery_address"]

  raise Kiosk::Server::Errors::BadRequest.new("missing field: order_id")         if order_id.nil? || order_id.to_s.empty?
  raise Kiosk::Server::Errors::BadRequest.new("missing field: delivery_slot_id") if delivery_slot_id.nil?
  raise Kiosk::Server::Errors::BadRequest.new("missing field: delivery_address") if delivery_address.nil? || delivery_address.to_s.empty?

  slot_id = delivery_slot_id.to_i
  raise Kiosk::Server::Errors::BadRequest.new("delivery_slot_id must be 1–6") unless (1..6).include?(slot_id)

  conn.transaction do
    # ── Gate 1: order belongs to principal and not already scheduled ─────
    order = conn.execute(
      "SELECT id FROM orders " \
      "WHERE id = #{conn.quote(order_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id() " \
      "AND status NOT IN ('scheduled') " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Forbidden.new("order not found, not yours, or already scheduled") if order.nil?

    # ── Gate 2: settled payment mandate referencing this order ────────────
    order_filter_json = [{ order_id: order_id.to_s }].to_json
    paid = conn.execute(
      "SELECT 1 AS ok " \
      "FROM kiosk.payment_mandates pm " \
      "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
      "WHERE pm.user_id = kiosk.current_user_id() " \
      "AND cm.line_items @> #{conn.quote(order_filter_json)}::jsonb " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Forbidden.new("no settled payment mandate for this order") if paid.nil?

    # ── Compute slot_at (slot 1 = 08:00, slot 2 = 10:00, ...) ────────────
    delivery_date = Date.today + 1
    hour          = 8 + (slot_id - 1) * 2
    slot_at       = Time.utc(delivery_date.year, delivery_date.month, delivery_date.day, hour, 0, 0)

    # ── Update order ──────────────────────────────────────────────────────
    conn.execute(
      "UPDATE orders " \
      "SET status = 'scheduled', slot_at = #{conn.quote(slot_at.iso8601)}::timestamptz, " \
      "    address = #{conn.quote(delivery_address.to_s)}, updated_at = now() " \
      "WHERE id = #{conn.quote(order_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id()"
    )

    { order_id: order_id, scheduled_at: slot_at.iso8601 }
  end
end
