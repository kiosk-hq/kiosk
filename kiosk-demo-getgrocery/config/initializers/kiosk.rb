# frozen_string_literal: true

# Kiosk-demo (getgrocery-shape) configuration.
# Grocery delivery with cart + substitution negotiation + delivery slot.
# No PoW, no KYC, no hardware unlock.
# Queries: stores, products_by_store, substitution_options, delivery_slots, my_orders
# Actions: add_to_cart, apply_substitution, confirm_delivery

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

# ─── Queries ────────────────────────────────────────────────────────────────

Kiosk::Server::Queries.register("stores",
  description: "Browse all available grocery stores") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, name, city FROM stores ORDER BY name"
  ).to_a
end

Kiosk::Server::Queries.register("products_by_store",
  description: "Browse products available at a specific store",
  params: {
    store_id: "integer — store id from the stores query",
  }) do |params|
  store_id = params.fetch(:store_id) { raise Kiosk::Server::Errors::BadRequest.new("missing param: store_id") }
  conn = ActiveRecord::Base.connection
  conn.execute(
    "SELECT id, sku, name, price_cents, stock " \
    "FROM products " \
    "WHERE store_id = #{conn.quote(store_id.to_s)}::integer " \
    "ORDER BY name"
  ).to_a
end

Kiosk::Server::Queries.register("substitution_options",
  description: "Get suggested substitute products when a product is low or out of stock",
  params: {
    product_id: "integer — product id that is low/out of stock",
  }) do |params|
  product_id = params.fetch(:product_id) { raise Kiosk::Server::Errors::BadRequest.new("missing param: product_id") }
  conn = ActiveRecord::Base.connection
  conn.execute(
    "SELECT sp.id AS policy_id, sp.out_product_id, sp.suggested_product_id, " \
    "  p.sku AS suggested_sku, p.name AS suggested_name, p.price_cents AS suggested_price_cents, p.stock AS suggested_stock " \
    "FROM substitution_policies sp " \
    "JOIN products p ON p.id = sp.suggested_product_id " \
    "WHERE sp.out_product_id = #{conn.quote(product_id.to_s)}::integer " \
    "ORDER BY p.name"
  ).to_a
end

Kiosk::Server::Queries.register("delivery_slots",
  description: "Get available delivery time slots for a given date",
  params: {
    date: "date string YYYY-MM-DD — desired delivery date",
  }) do |params|
  date = params.fetch(:date) { raise Kiosk::Server::Errors::BadRequest.new("missing param: date") }

  # Generate synthetic 2-hour delivery slots for the requested date.
  # Slots: 08:00, 10:00, 12:00, 14:00, 16:00, 18:00 (6 slots).
  parsed = begin
    Date.parse(date.to_s)
  rescue ArgumentError
    raise Kiosk::Server::Errors::BadRequest.new("invalid date: #{date}")
  end

  slots = (0..5).map do |i|
    hour = 8 + i * 2
    slot_time = Time.utc(parsed.year, parsed.month, parsed.day, hour, 0, 0)
    {
      "id"        => i + 1,
      "slot_at"   => slot_time.iso8601,
      "label"     => "#{hour.to_s.rjust(2, "0")}:00–#{(hour + 2).to_s.rjust(2, "0")}:00",
      "available" => true,
    }
  end
  slots
end

Kiosk::Server::Queries.register("my_orders",
  description: "List this principal's grocery deliveries (scoped to authenticated user via kiosk.current_user_id())") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT d.id, d.cart_id, d.slot_at, d.address, d.status, d.created_at " \
    "FROM deliveries d " \
    "WHERE d.user_id = kiosk.current_user_id() " \
    "ORDER BY d.created_at DESC"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

Kiosk::Server::Actions.register("add_to_cart",
  description: "Add a product to the authenticated principal's open cart for a store (creates cart if needed)",
  params: {
    store_id:   "integer — store id",
    product_id: "integer — product id",
    qty:        "integer — quantity (default 1)",
  }) do |args|
  conn = ActiveRecord::Base.connection
  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  store_id   = args.fetch(:store_id)   { raise Kiosk::Server::Errors::BadRequest.new("missing field: store_id") }
  product_id = args.fetch(:product_id) { raise Kiosk::Server::Errors::BadRequest.new("missing field: product_id") }
  qty        = (args[:qty] || 1).to_i
  raise Kiosk::Server::Errors::BadRequest.new("qty must be >= 1") if qty < 1

  conn.transaction do
    # Find or create the open cart for this user+store
    cart = conn.execute(
      "SELECT id FROM carts " \
      "WHERE user_id = #{conn.quote(uid)}::uuid " \
      "AND store_id = #{conn.quote(store_id.to_s)}::integer " \
      "AND status = 'open' " \
      "LIMIT 1"
    ).first

    if cart.nil?
      cart = conn.execute(
        "INSERT INTO carts (user_id, store_id, status, created_at, updated_at) " \
        "VALUES (#{conn.quote(uid)}::uuid, #{conn.quote(store_id.to_s)}::integer, 'open', now(), now()) " \
        "RETURNING id"
      ).first
    end

    cart_id = cart["id"]

    # Upsert the cart_item (increment qty if exists)
    existing_item = conn.execute(
      "SELECT id, qty FROM cart_items " \
      "WHERE cart_id = #{conn.quote(cart_id.to_s)}::uuid " \
      "AND product_id = #{conn.quote(product_id.to_s)}::integer " \
      "LIMIT 1"
    ).first

    cart_item_id = if existing_item
      new_qty = existing_item["qty"].to_i + qty
      conn.execute(
        "UPDATE cart_items SET qty = #{new_qty}, updated_at = now() " \
        "WHERE id = #{conn.quote(existing_item["id"].to_s)}::integer " \
        "RETURNING id"
      ).first["id"]
    else
      conn.execute(
        "INSERT INTO cart_items (cart_id, product_id, qty, substituted, created_at, updated_at) " \
        "VALUES (#{conn.quote(cart_id.to_s)}::uuid, #{conn.quote(product_id.to_s)}::integer, " \
        "#{qty}, false, now(), now()) " \
        "RETURNING id"
      ).first["id"]
    end

    { cart_id: cart_id, cart_item_id: cart_item_id }
  end
end

Kiosk::Server::Actions.register("apply_substitution",
  description: "Accept or reject a substitution for an out-of-stock cart item (ownership-gated to the cart's user)",
  params: {
    cart_id:                 "uuid — the cart id (must belong to the authenticated principal)",
    cart_item_id:            "integer — the cart item id to substitute",
    substitution_product_id: "integer — the substitute product id",
    accept:                  "boolean — true to accept the substitution, false to reject/remove",
  }) do |args|
  conn = ActiveRecord::Base.connection

  cart_id                 = args.fetch(:cart_id)                 { raise Kiosk::Server::Errors::BadRequest.new("missing field: cart_id") }
  cart_item_id            = args.fetch(:cart_item_id)            { raise Kiosk::Server::Errors::BadRequest.new("missing field: cart_item_id") }
  substitution_product_id = args.fetch(:substitution_product_id) { raise Kiosk::Server::Errors::BadRequest.new("missing field: substitution_product_id") }
  accept                  = args.fetch(:accept)                  { raise Kiosk::Server::Errors::BadRequest.new("missing field: accept") }

  conn.transaction do
    # OWNERSHIP GATE: cart must belong to the authenticated principal
    cart = conn.execute(
      "SELECT id FROM carts " \
      "WHERE id = #{conn.quote(cart_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id() " \
      "AND status = 'open' " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Forbidden.new("cart not found or not yours") if cart.nil?

    # Verify the cart item belongs to this cart
    item = conn.execute(
      "SELECT id, product_id, qty, substituted FROM cart_items " \
      "WHERE id = #{conn.quote(cart_item_id.to_s)}::integer " \
      "AND cart_id = #{conn.quote(cart_id.to_s)}::uuid " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::BadRequest.new("cart item not found in this cart") if item.nil?

    if accept
      # Swap the product to the substitute
      conn.execute(
        "UPDATE cart_items " \
        "SET product_id = #{conn.quote(substitution_product_id.to_s)}::integer, " \
        "    substituted = true, " \
        "    updated_at = now() " \
        "WHERE id = #{conn.quote(cart_item_id.to_s)}::integer " \
        "AND cart_id = #{conn.quote(cart_id.to_s)}::uuid"
      )
      updated = conn.execute(
        "SELECT id, cart_id, product_id, qty, substituted FROM cart_items " \
        "WHERE id = #{conn.quote(cart_item_id.to_s)}::integer LIMIT 1"
      ).first
      { accepted: true, cart_item: updated }
    else
      # Remove the item from the cart
      conn.execute(
        "DELETE FROM cart_items " \
        "WHERE id = #{conn.quote(cart_item_id.to_s)}::integer " \
        "AND cart_id = #{conn.quote(cart_id.to_s)}::uuid"
      )
      { accepted: false, cart_item_id: cart_item_id, removed: true }
    end
  end
end

Kiosk::Server::Actions.register("confirm_delivery",
  description: "Confirm the delivery for a cart, scheduling a slot (ownership-gated to the cart's user)",
  params: {
    cart_id:          "uuid — the cart to confirm (must belong to the authenticated principal)",
    delivery_slot_id: "integer — slot id from the delivery_slots query",
    delivery_address: "string — delivery address",
  }) do |args|
  conn = ActiveRecord::Base.connection

  cart_id          = args.fetch(:cart_id)          { raise Kiosk::Server::Errors::BadRequest.new("missing field: cart_id") }
  delivery_slot_id = args.fetch(:delivery_slot_id) { raise Kiosk::Server::Errors::BadRequest.new("missing field: delivery_slot_id") }
  delivery_address = args.fetch(:delivery_address) { raise Kiosk::Server::Errors::BadRequest.new("missing field: delivery_address") }

  conn.transaction do
    # OWNERSHIP GATE: cart must belong to the authenticated principal and be open
    cart = conn.execute(
      "SELECT c.id, c.store_id FROM carts c " \
      "WHERE c.id = #{conn.quote(cart_id.to_s)}::uuid " \
      "AND c.user_id = kiosk.current_user_id() " \
      "AND c.status = 'open' " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Forbidden.new("cart not found or not yours") if cart.nil?

    # Compute total_cents from cart items
    total_row = conn.execute(
      "SELECT COALESCE(SUM(ci.qty * p.price_cents), 0) AS total_cents " \
      "FROM cart_items ci " \
      "JOIN products p ON p.id = ci.product_id " \
      "WHERE ci.cart_id = #{conn.quote(cart_id.to_s)}::uuid"
    ).first
    total_cents = total_row["total_cents"].to_i

    # Compute slot_at from slot_id (slots 1-6: hour = 6 + slot_id * 2)
    slot_id = delivery_slot_id.to_i
    raise Kiosk::Server::Errors::BadRequest.new("delivery_slot_id must be 1-6") unless (1..6).include?(slot_id)
    delivery_date = Date.today + 1  # Default to tomorrow if not specified
    hour = 6 + slot_id * 2
    slot_at = Time.utc(delivery_date.year, delivery_date.month, delivery_date.day, hour, 0, 0)

    uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]

    # Create delivery row
    delivery = conn.execute(
      "INSERT INTO deliveries (user_id, cart_id, slot_at, address, status, created_at, updated_at) " \
      "VALUES (" \
      "  #{conn.quote(uid)}::uuid, " \
      "  #{conn.quote(cart_id.to_s)}::uuid, " \
      "  #{conn.quote(slot_at.iso8601)}::timestamp, " \
      "  #{conn.quote(delivery_address.to_s)}, " \
      "  'scheduled', now(), now()" \
      ") RETURNING id"
    ).first
    delivery_id = delivery["id"]

    # Mark cart as confirmed
    conn.execute(
      "UPDATE carts SET status = 'confirmed', updated_at = now() " \
      "WHERE id = #{conn.quote(cart_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id()"
    )

    {
      delivery_id:  delivery_id,
      total_cents:  total_cents,
      scheduled_at: slot_at.iso8601,
    }
  end
end
