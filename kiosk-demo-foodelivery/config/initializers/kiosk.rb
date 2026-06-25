# frozen_string_literal: true

# Kiosk-demo (foodelivery-shape) configuration. Concrete values for the
# food-delivery reference shape: uuid users, JWT-or-stub IdP, StubPsp,
# one Action registered (place_order).

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")

# ── PoW / Reputation (R2) — activated only when KIOSK_POW_DEMO=1 ──────────
#
# Gate: the Argon2id PoW challenge is issued ONLY for the :query verb.
# The :run and :pay verbs are left ungated so that the existing no-human
# order flow (order_flow.rb / rake demo:order) continues to pass without
# any PoW handling.
#
# The guard is intentional:
#   - rake demo:order boots the server WITHOUT KIOSK_POW_DEMO=1 → no PoW.
#   - rake demo:pow   boots the server WITH   KIOSK_POW_DEMO=1 → PoW active.
#
# Difficulty d: 5 leading zero bits → solve.py completes in ~1–2 seconds.
# Memory: m=8192 KiB (8 MiB) — small enough for a laptop demo, still
# memory-hard (ASIC-resistant for the demo purpose).

if ENV["KIOSK_POW_DEMO"] == "1"
  require "kiosk/pow"
  require "kiosk/reputation"

  Kiosk::Reputation::Backends.register(Kiosk::Pow::NAME, Kiosk::Pow)

  # Demo policy: always challenge :query; let :run/:pay through freely.
  # A real provider replaces this with Policies::RateAndReputation or a
  # domain-specific subclass. The inline class keeps the demo self-contained.
  class FoodeliveryDemoPowPolicy < Kiosk::Reputation::Policy
    def initialize(pow_params)
      @pow_params = pow_params
    end

    # @return [{alg:, params:}] when verb is :query; nil otherwise.
    def challenge_for(identity:, verb:, factors:)
      return nil unless verb == :query

      { alg: Kiosk::Pow::NAME, params: @pow_params }
    end
  end

  # Counter file written by on_bad_proof; the pow_flow.rb driver reads it.
  FOODELIVERY_BAD_PROOF_FILE = "/tmp/kiosk-foodelivery-bad-proof.count"
  File.write(FOODELIVERY_BAD_PROOF_FILE, "0")
end

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

  # ── PoW gate (active only when KIOSK_POW_DEMO=1) ──────────────────────
  if ENV["KIOSK_POW_DEMO"] == "1"
    # Small cost for demo speed: d=5 bits (~1–2 s on solve.py), m=8 MiB.
    pow_params = Kiosk::Pow.params(d: 5, m: 8_192, t: 1, p: 1)

    c.reputation_policy = FoodeliveryDemoPowPolicy.new(pow_params)
    c.pow_secret        = ENV.fetch("KIOSK_POW_SECRET", "demo-pow-secret")
    c.pow_ttl           = 300

    # Factors: always return empty (the demo policy ignores factors and
    # challenges :query unconditionally). A real provider wires DB lookups.
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }

    # on_bad_proof: increment the counter file so pow_flow.rb can assert it.
    c.on_bad_proof = ->(identity:) {
      count = (File.read(FOODELIVERY_BAD_PROOF_FILE).to_i rescue 0)
      File.write(FOODELIVERY_BAD_PROOF_FILE, (count + 1).to_s)
    }
  end
end

# ─── Queries ────────────────────────────────────────────────────────────────

# restaurants — public restaurant catalog. No per-user scoping: all
# authenticated agents can browse available restaurants.
Kiosk::Server::Queries.register("restaurants") do |_params|
  ActiveRecord::Base.connection.execute("SELECT id, name FROM restaurants ORDER BY id").to_a
end

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
