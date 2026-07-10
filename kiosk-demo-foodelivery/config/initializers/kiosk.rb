# frozen_string_literal: true

# Kiosk-demo (foodelivery-shape) configuration. Concrete values for the
# food-delivery reference shape: uuid users, JWT-or-stub IdP, StubPsp,
# one Action registered (place_order).

# ── Ephemeral dev signing key (K-034) ────────────────────────────────────
# JWT / register flows need a signing key. In development or test, if none is
# provided, self-provision an EPHEMERAL RSA key so `demo:setup` and the flows
# run out-of-the-box. Never do this in production — a real key must be set.
if ENV["KIOSK_SIGNING_KEY_B64"].nil? && ENV["KIOSK_SIGNING_KEY_PEM"].nil? && Rails.env.local?
  require "openssl"
  require "base64"
  ENV["KIOSK_SIGNING_KEY_B64"] = Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)
  warn "[kiosk] WARNING: generated an EPHEMERAL signing key (#{Rails.env}); set KIOSK_SIGNING_KEY_B64/PEM for a stable key."
end

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")

# ── PoW / Reputation (R2) — activated only when KIOSK_POW_DEMO=1 ──────────
#
# Gate: the Equihash PoW challenge is issued ONLY for the :query verb.
# The :run and :pay verbs are left ungated so that the existing no-human
# order flow (order_flow.rb / rake demo:order) continues to pass without
# any PoW handling.
#
# The guard is intentional:
#   - rake demo:order boots the server WITHOUT KIOSK_POW_DEMO=1 → no PoW.
#   - rake demo:pow   boots the server WITH   KIOSK_POW_DEMO=1 → PoW active.
#
# Demo params: n=96, k=5 — a small, non-toy Equihash instance the reference
# solver clears in well under a second. Production defaults (n=168, k=7) are
# ~10 s; a demo wants speed. See ADR-0007: PoW is a metered toll, tuned per
# provider, not a hardware wall.
EQUIHASH_DEMO_PARAMS = { n: 96, k: 5 }.freeze

if ENV["KIOSK_POW_DEMO"] == "1"
  require "kiosk/pow/equihash"
  require "kiosk/reputation"

  Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

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

      { alg: Kiosk::Pow::Equihash::NAME, params: @pow_params }
    end
  end

  # Counter file written by on_bad_proof; the pow_flow.rb driver reads it.
  FOODELIVERY_BAD_PROOF_FILE = "/tmp/kiosk-foodelivery-bad-proof.count"
  File.write(FOODELIVERY_BAD_PROOF_FILE, "0")
end

# ── Reputation PoW gate (R2 P6) — activated only when KIOSK_POW_REPUTATION_DEMO=1 ──
#
# Demonstrates the "trust-earned-by-spending" thesis end-to-end using the
# shipped RateAndReputation policy, escalating by PROOF COUNT (N×PoW):
#   0 purchases → count = base_count(1) + unproven_count_bonus(1) = 2 proofs
#   1 purchase  → count = base_count(1) = 1 proof (purchase earns relief)
#   2+ purchases → free pass (proven?(purchases) → challenge_for returns nil)
#
# The factors callable performs a REAL DB lookup: COUNT(*) on kiosk.settlements
# for the authenticated principal — no faking. Equihash params are the small
# demo instance so each proof solves in well under a second.

if ENV["KIOSK_POW_REPUTATION_DEMO"] == "1"
  require "kiosk/pow/equihash"
  require "kiosk/reputation"

  Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

  FOODELIVERY_REPUTATION_BAD_PROOF_FILE = "/tmp/kiosk-foodelivery-reputation-bad-proof.count"
  File.write(FOODELIVERY_REPUTATION_BAD_PROOF_FILE, "0")
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
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  c.owner  = { name: "foodelivery", support: "help@foodelivery.app" }
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_sha256 = "9f7a68a17cf3f36be9fc215d277efcac980693f2fe8366d0cea50c57f08e415c"

  # ── RLS enforce gate (R1 Phase 1 Task 5 — demo:rls only) ─────────────────
  # When KIOSK_RLS_ENFORCE=1, SessionContext.open appends
  #   SET LOCAL ROLE "kiosk_foodelivery_app"
  # after the GUC statements, dropping the session to the non-owner app role
  # for the duration of the transaction.  The non-owner role is subject to
  # the RLS policies applied by demo:rls (ENABLE + FORCE + per-user SELECT/INSERT
  # policies on the orders table).
  #
  # When unset (default), enforce_db_role = false and app_role falls back to the
  # ENV-driven default ("app_role") — no role-drop, byte-identical to the
  # pre-T5 behaviour (Path-C demo:order / demo:isolation / demo:pow / demo:cuckoo).
  if ENV["KIOSK_RLS_ENFORCE"] == "1"
    c.enforce_db_role = true
    c.app_role        = "kiosk_foodelivery_app"
  end

  # JwtOrStubIdp tries Kiosk-issued JWTs (Device-Grant output) first,
  # then falls back to StubIdp's bespoke `agent:u-…:a-…:r-…` shape.
  # One endpoint authenticates both for the demo. Real providers swap
  # in `kiosk-user-idp-devise` (or another adapter); see the README.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # user_idp not needed — composite handles both channels.

  # Payment provider — stub for the demo; swap in kiosk-pay-stripe for real.
  c.payment_provider = StubPsp.new

  # ── Equihash PoW gate (active only when KIOSK_POW_DEMO=1) ───────────────
  if ENV["KIOSK_POW_DEMO"] == "1"
    # Small, non-toy Equihash instance for demo speed (sub-second solve).
    pow_params = Kiosk::Pow::Equihash.params(**EQUIHASH_DEMO_PARAMS)

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

  # ── Reputation PoW gate (active only when KIOSK_POW_REPUTATION_DEMO=1) ────
  # Uses the shipped RateAndReputation policy with REAL purchase-count factors,
  # escalating by PROOF COUNT (N×PoW):
  #   proven_purchases_threshold: 2  → 2 settled purchases → free pass
  #   base_count: 1, unproven_count_bonus: 1 → 0 purchases: 2 proofs;
  #                                            1 purchase: 1 proof; 2+: nil
  if ENV["KIOSK_POW_REPUTATION_DEMO"] == "1"
    c.reputation_policy = Kiosk::Reputation::Policies::RateAndReputation.new(
      proven_purchases_threshold: 2,
      low_rate_threshold:         100,
      base_count:                 1,
      count_min:                  1,
      count_max:                  10,
      rate_count_step:            1,
      rate_step:                  10,
      unproven_count_bonus:       1,
      bad_proof_count_factor:     3,
      equihash_n:                 EQUIHASH_DEMO_PARAMS[:n],
      equihash_k:                 EQUIHASH_DEMO_PARAMS[:k],
    )
    c.pow_secret = ENV.fetch("KIOSK_POW_SECRET", "demo-pow-secret")
    c.pow_ttl    = 300

    # Factors: real DB lookup — COUNT(*) on kiosk.settlements for this principal.
    # request_rate_per_min and bad_proof_count are fixed at 0 for the demo.
    c.reputation_factors = ->(identity:, **) {
      uid  = identity.user_id
      conn = ActiveRecord::Base.connection
      count = conn.execute(
        "SELECT COUNT(*) AS settled_count FROM kiosk.settlements " \
        "WHERE user_id = #{conn.quote(uid.to_s)}"
      ).first["settled_count"].to_i
      Kiosk::Reputation::Factors.new(
        kyc_level:               nil,
        settled_purchases_count: count,
        settled_purchases_cents: nil,
        request_rate_per_min:    0,
        account_age_seconds:     nil,
        dispute_count:           nil,
        bad_proof_count:         0,
      )
    }

    c.on_bad_proof = ->(identity:) {
      cnt = (File.read(FOODELIVERY_REPUTATION_BAD_PROOF_FILE).to_i rescue 0)
      File.write(FOODELIVERY_REPUTATION_BAD_PROOF_FILE, (cnt + 1).to_s)
    }
  end
end

# ─── Queries ────────────────────────────────────────────────────────────────

# restaurants — public restaurant catalog. No per-user scoping: all
# authenticated agents can browse available restaurants.
Kiosk::Server::Queries.register("restaurants",
                                 description: "Browse the public restaurant catalog") do |_params|
  ActiveRecord::Base.connection.execute("SELECT id, name FROM restaurants ORDER BY id").to_a
end

# menu_by_restaurant — parameterized menu catalog for a named restaurant.
# The agent supplies :restaurant (the restaurant name); the block builds the
# query with conn.quote binding — agent input is data, never SQL.
# No per-user scoping: all authenticated agents can browse the menu.
Kiosk::Server::Queries.register("menu_by_restaurant",
                                 description: "Browse menu items for a named restaurant",
                                 params: { restaurant: "string — restaurant name" }) do |params|
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
Kiosk::Server::Queries.register("my_orders",
                                 description: "List this principal's placed orders (scoped to authenticated user via kiosk.current_user_id())") do |_params|
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
Kiosk::Server::Actions.register("place_order",
                                  description: "Place a food order for the authenticated principal",
                                  params: {
                                    menu_item_id:     "integer — id of the menu item to order",
                                    quantity:         "integer — number of items (default 1)",
                                    delivery_address: "string — delivery address",
                                  }) do |args|
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
