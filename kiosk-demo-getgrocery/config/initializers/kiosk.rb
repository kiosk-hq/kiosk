# frozen_string_literal: true

# Kiosk-demo (getgrocery-shape) configuration.
# Single grocery provider — no store layer. Catalog exposes in-stock facts;
# the AI assistant handles substitution decisions.
# Queries:  catalog, delivery_slots, my_orders
# Actions:  create_order, schedule_delivery, payment_setup

# ── Ephemeral dev signing key ─────────────────────────────────────────────
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
require Rails.root.join("lib/stub_user_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/pow_difficulty")
require "kiosk/payment_providers/stripe"

ActiveRecord::Migration.include(Kiosk::RLS::DSL)

# ── Commerce catalog-toll PoW demo (KIOSK_POW_DEMO=1) ─────────────────────
#
# A grocery provider can toll the `catalog` query to price anonymous browsing
# (a metered toll, not a wall). Params follow KIOSK_POW_DIFFICULTY
# (lib/pow_difficulty.rb): low (default) → n=96 k=5 sub-second; high → n=168 k=7
# (~10s / ~1.3 GiB). getgrocery ships low (the flagship stays poke-friendly for
# the full shop flow); the knob is here for parity. run/pay are never gated.
EQUIHASH_DEMO_PARAMS = PowDifficulty.params

if ENV["KIOSK_POW_DEMO"] == "1"
  require "kiosk/pow/equihash"
  require "kiosk/reputation"
  Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

  GETGROCERY_BAD_PROOF_FILE = "/tmp/kiosk-getgrocery-bad-proof.count"
  File.write(GETGROCERY_BAD_PROOF_FILE, "0")

  class GetgroceryCatalogPowPolicy < Kiosk::Reputation::Policy
    def initialize(params)
      @params = params
    end

    def challenge_for(identity:, verb:, factors:)
      return nil unless verb == :query

      { alg: Kiosk::Pow::Equihash::NAME, params: @params }
    end
  end
end

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  # ── RLS enforce gate (demo:rls only) ─────────────────────────────────────
  # When KIOSK_RLS_ENFORCE=1, SessionContext.open appends
  #   SET LOCAL ROLE "kiosk_getgrocery_app"
  # after the GUC statements, dropping the session to the non-owner app role
  # for the duration of the transaction. That non-owner role is subject to the
  # RLS policies applied by demo:rls (ENABLE + FORCE + per-user SELECT/INSERT
  # policies on the orders table). When unset (default) there is no role-drop —
  # byte-identical to the normal shop path.
  if ENV["KIOSK_RLS_ENFORCE"] == "1"
    c.enforce_db_role = true
    c.app_role        = "kiosk_getgrocery_app"
  end

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3005")
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. A
  # "beware: intensive PoW" notice appears only when KIOSK_POW_DIFFICULTY=high
  # (getgrocery ships low, so normally absent).
  c.owner  = { name: "GetGrocery", support: "help@getgrocery.com" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.6.md"
  c.skill_sha256 = "d27a9184da55b27ae42833987f9ae6c6afbc9fba75ca98103370d51f67865ef7"

  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # The provider's own web-session channel: authenticates the approving
  # human on the account-binding surfaces (device verify page, link mint,
  # unlink). A stub because this demo has no human login UI — see
  # lib/stub_user_idp.rb for the honest scope; `rake demo:claim` walks
  # the claim-rebind ceremony through it.
  c.user_idp = StubUserIdp.new

  # Payment provider: real Stripe in test mode (sk_test_…).
  # getgrocery uses SetupIntent card-on-file: card saved once on Stripe's
  # hosted page, charged off_session per purchase.
  #
  # The principal→Stripe Customer mapping is stored in `stripe_customers` and
  # injected as lambdas — the kiosk-pay-stripe gem stays provider-agnostic.
  #
  # Real Stripe by default (demo:shop → real pi_…). When STRIPE_MOCK_URL is set
  # (the adversarial suites), point the SDK at a local stripe-mock instead —
  # fast, no key, no real charges. stripe-mock returns shaped fixtures, so the
  # full pay→settlement flow runs and the Kiosk gates (ownership + "settlement
  # exists") are exercised end-to-end without hitting Stripe.
  if (mock = ENV["STRIPE_MOCK_URL"]) && !mock.empty?
    require "stripe"
    Stripe.api_base = mock                          # e.g. http://127.0.0.1:12111
    key = ENV["STRIPE_SECRET_KEY"].to_s.empty? ? "sk_test_mock" : ENV["STRIPE_SECRET_KEY"]
  else
    key = ENV["STRIPE_SECRET_KEY"]
    if key.nil? || key.empty?
      # Out-of-box parity with the sibling demos: in dev/test the
      # app boots on a placeholder so db:setup/schema/isolation/redteam run with
      # no payment config; only a REAL charge (demo:shop) needs a live key or
      # STRIPE_MOCK_URL, and fails clearly at charge time if neither is set.
      raise "getgrocery requires STRIPE_SECRET_KEY (sk_test_…) or STRIPE_MOCK_URL" unless Rails.env.local?
      warn "[getgrocery] no STRIPE_SECRET_KEY/STRIPE_MOCK_URL set — using a placeholder key; demo:shop needs one to charge."
      key = "sk_test_placeholder"
    end
  end

  # KIOSK_TEST_AUTOCARD=1 (set by the demo/redteam/isolation rake tasks) makes the
  # adapter simulate a completed SetupIntent — automated suites need no card-setup
  # step and no server-side test route. NEVER set in production or the live demo,
  # where the real hosted SetupIntent flow runs (human enters the card once).
  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(
    api_key:           key,
    customer_resolver: ->(uid) { StripeCustomer.find_by(user_id: uid)&.customer_id },
    customer_saver:    ->(uid, cid) { StripeCustomer.create!(user_id: uid, customer_id: cid) },
    test_autocard:     ENV["KIOSK_TEST_AUTOCARD"] == "1",
    return_url:        "#{Kiosk.configuration.issuer}/payment/return",
  )

  # ── Catalog-toll PoW gate (active only when KIOSK_POW_DEMO=1) ────────────
  if ENV["KIOSK_POW_DEMO"] == "1"
    c.reputation_policy  = GetgroceryCatalogPowPolicy.new(Kiosk::Pow::Equihash.params(**EQUIHASH_DEMO_PARAMS))
    c.pow_secret         = ENV.fetch("KIOSK_POW_SECRET", "getgrocery-demo-pow-secret")
    c.pow_ttl            = 300
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }
    c.on_bad_proof = ->(identity:) {
      n = (File.read(GETGROCERY_BAD_PROOF_FILE).to_i rescue 0)
      File.write(GETGROCERY_BAD_PROOF_FILE, (n + 1).to_s)
    }
  end
end

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. When on, one event is recorded per successful
# wire action via a Rack middleware; the aggregate is served at
# GET /demo/activity.json. NOT part of kiosk-core (satellite neutrality).
# GETGROCERY_VERB_MAP maps this vertical's concrete run-verbs onto the generic
# action kinds so the landing aggregate reads uniformly across demos.
if ENV["KIOSK_TELEMETRY"] == "1"
  require Rails.root.join("lib/demo_telemetry")
  GETGROCERY_VERB_MAP = {
    "create_order"      => "ordered",
    "schedule_delivery" => "scheduled",
    "payment_setup"     => "ran",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: GETGROCERY_VERB_MAP,
  )
end

LOW_STOCK_THRESHOLD = 5

# ─── Queries ────────────────────────────────────────────────────────────────

Kiosk::Server::Queries.register("catalog",
  description: "Browse in-stock products from the getgrocery catalog (out-of-stock items are hidden)") do |_params|
  conn = ActiveRecord::Base.connection
  rows = conn.execute(
    "SELECT sku, name, price_cents, stock FROM products WHERE stock > 0 ORDER BY name"
  ).to_a
  rows.map do |r|
    row = { "sku" => r["sku"], "name" => r["name"], "price_cents" => r["price_cents"] }
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

Kiosk::Server::Actions.register("payment_setup",
  description: "Check whether the authenticated principal has a saved card on file. " \
               "Returns {status: \"ready\"} if a card is already saved and the assistant can proceed to `pay`. " \
               "Returns {status: \"setup_required\", setup_url: \"…\"} when no card is saved — " \
               "the assistant must hand the setup_url to the human, wait for them to complete the " \
               "Stripe-hosted card entry, then call payment_setup again before paying. " \
               "The assistant should call this before every `pay` invocation on a new device or session.",
  params: {}) do |_args|
  conn     = ActiveRecord::Base.connection
  uid      = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  provider = Kiosk.configuration.payment_provider
  issuer   = Kiosk.configuration.issuer

  # Key off setup_required? (not saved_method?) so it honours the adapter's
  # policy — incl. KIOSK_TEST_AUTOCARD, where setup is auto-completed at capture
  # and this returns "ready" without a hosted-page round-trip.
  if provider.setup_required?(user_id: uid)
    { status: "setup_required", setup_url: provider.setup_url(user_id: uid) }
  else
    { status: "ready" }
  end
end

Kiosk::Server::Actions.register("create_order",
  description: "Create (or replace) a grocery order for the authenticated principal. " \
               "To pay for it, sign your AP2 cart mandate with line_items that include " \
               "{\"order_id\": <the returned order_id>} — settlements are matched to orders " \
               "by that reference, and schedule_delivery requires it (the result carries a pay_hint)",
  params: {
    items:    "array of {sku, qty} — the complete cart (products referenced by sku)",
    order_id: "(optional) uuid — if given and order belongs to principal and not yet paid, replaces its items",
  }) do |args|
  conn = ActiveRecord::Base.connection
  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  items = args[:items] || args["items"] || []
  raise Kiosk::Server::Errors::BadRequest.new("items must be a non-empty array") if items.empty?

  items = items.map do |it|
    sku = (it[:sku] || it["sku"]).to_s
    qty = (it[:qty] || it["qty"] || 1).to_i
    raise Kiosk::Server::Errors::BadRequest.new("each item needs a sku") if sku.empty?
    raise Kiosk::Server::Errors::BadRequest.new("qty must be >= 1") if qty < 1
    { sku: sku, qty: qty }
  end

  conn.transaction do
    # Resolve skus → product id + price (consumer references products by sku, not the numeric id)
    quoted_skus = items.map { |i| conn.quote(i[:sku]) }.uniq.join(", ")
    product_rows = conn.execute(
      "SELECT id, sku, price_cents FROM products WHERE sku IN (#{quoted_skus})"
    ).to_a
    by_sku = product_rows.each_with_object({}) { |r, h| h[r["sku"]] = r }

    missing = items.map { |i| i[:sku] }.uniq.reject { |s| by_sku.key?(s) }
    raise Kiosk::Server::Errors::BadRequest.new("unknown sku(s): #{missing.join(", ")}") unless missing.empty?

    total_cents = items.sum { |i| by_sku[i[:sku]]["price_cents"].to_i * i[:qty] }

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

    # Insert order_items (resolve each sku → internal product id)
    items.each do |item|
      product_id = by_sku[item[:sku]]["id"]
      conn.execute(
        "INSERT INTO order_items (order_id, product_id, qty, created_at, updated_at) " \
        "VALUES (#{conn.quote(order_id.to_s)}::uuid, #{conn.quote(product_id.to_s)}::integer, " \
        "#{conn.quote(item[:qty].to_s)}::integer, now(), now())"
      )
    end

    {
      order_id:    order_id,
      total_cents: total_cents,
      pay_hint:    "pay with a cart mandate whose line_items include " \
                   "{\"order_id\": \"#{order_id}\"} — schedule_delivery unlocks " \
                   "only once a settlement references this order that way",
    }
  end
end

Kiosk::Server::Actions.register("schedule_delivery",
  description: "Schedule delivery for a paid order. Requires a settlement whose cart-mandate " \
               "line_items include {\"order_id\": <order_id>} — pay that way first " \
               "(see create_order's pay_hint), then schedule",
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

    # ── Gate 2: settlement (capture receipt) referencing this order ──────────
    order_filter_json = [{ order_id: order_id.to_s }].to_json
    paid = conn.execute(
      "SELECT 1 AS ok " \
      "FROM kiosk.settlements pm " \
      "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
      "WHERE pm.user_id = kiosk.current_user_id() " \
      "AND cm.line_items @> #{conn.quote(order_filter_json)}::jsonb " \
      "LIMIT 1"
    ).first
    if paid.nil?
      raise Kiosk::Server::Errors::Forbidden.new(
        "no settlement references this order — pay with a cart mandate whose " \
        "line_items include {\"order_id\": \"#{order_id}\"}, then retry"
      )
    end

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
