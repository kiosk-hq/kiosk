# frozen_string_literal: true

# Kiosk-demo (foodelivery-shape) configuration. Concrete values for the
# food-delivery reference shape: uuid users, JWT-or-stub IdP, StubPsp,
# one Action registered (place_order).

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")

# Inject the RLS DSL into ActiveRecord::Migration so that migrations can
# call `enable_rls_on TABLE do ... end` directly. The kiosk-rls README
# documents this opt-in; auto-injection from the gem itself lands in a
# follow-up.
ActiveRecord::Migration.include(Kiosk::RLS::DSL)

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in v0.1 alpha). Set app_role to the same role so the
  # `GRANT TO app_role` statements in `enable_rls_on` are no-ops on a
  # role that already has all privileges via ownership.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3002")
  c.roles  = %i[customer]
  c.owner  = { name: "foodelivery", support: "help@foodelivery.app" }

  # JwtOrStubIdp tries Kiosk-issued JWTs (Device-Grant output) first,
  # then falls back to StubIdp's bespoke `agent:u-…:a-…:r-…` shape.
  # One endpoint authenticates both for the demo. Real providers swap
  # in `kiosk-user-idp-devise` (or another adapter); see the README.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # user_idp not needed — composite handles both channels.

  # Payment provider — stub for the demo; swap in kiosk-pay-stripe for real.
  c.payment_provider = StubPsp.new
end

# ─── Queries ────────────────────────────────────────────────────────────────

# menu_by_restaurant — parameterized menu catalog for a named restaurant.
# The agent supplies :restaurant (the restaurant name); the block builds the
# query with conn.quote binding — agent input is data, never SQL.
# No per-user scoping: all authenticated agents can browse the menu.
Kiosk::Server::Queries.register("menu_by_restaurant") do |params|
  name = params.fetch(:restaurant) { raise Kiosk::Server::Errors::BadRequest.new("missing param: restaurant") }
  conn = ActiveRecord::Base.connection
  conn.execute(
    "SELECT mi.id, mi.name, mi.sku, mi.price_cents " \
    "FROM menu_items mi " \
    "JOIN restaurants r ON r.id = mi.restaurant_id " \
    "WHERE r.name = #{conn.quote(name.to_s)} " \
    "ORDER BY mi.id"
  ).to_a
end

# my_orders — per-user order list scoped by the session GUC.
# The WHERE is provider-controlled; the agent supplies no filter. This
# demonstrates app-layer per-user isolation without RLS: the principal can
# only see rows where user_id matches kiosk.current_user_id(), enforced in
# the query definition itself.
Kiosk::Server::Queries.register("my_orders") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, restaurant_id, menu_item_id, total_cents, status " \
    "FROM orders " \
    "WHERE user_id = kiosk.current_user_id() " \
    "ORDER BY id"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

# Register the demo Action. In production, providers use the full
# `Kiosk::Action` DSL (post-v0.1); for the e2e a simple registered
# block is sufficient.
Kiosk::Server::Actions.register("place_order") do |args|
  # Identity is set via Kiosk::Server::SessionContext SET LOCAL —
  # current_user_id() helper returns the principal. ActiveRecord doesn't
  # have direct access; pull from PG.
  uid = ActiveRecord::Base.connection.execute(
    "SELECT kiosk.current_user_id() AS uid"
  ).first["uid"]

  item = MenuItem.find(args[:menu_item_id])
  qty  = (args[:quantity] || 1).to_i

  order = Order.create!(
    user_id:          uid,
    restaurant_id:    item.restaurant_id,
    menu_item_id:     item.id,
    quantity:         qty,
    total_cents:      item.price_cents * qty,
    delivery_address: args.fetch(:delivery_address),
  )

  { order_id: order.id, restaurant_id: order.restaurant_id, total_cents: order.total_cents, status: order.status }
end
