# frozen_string_literal: true

# Kiosk-demo (hoteling-shape) configuration. Hotel booking with payment gate.
# No KYC, no hardware unlock. PoW is off by default; with
# KIOSK_POW_BROWSE_DEMO=1 the browse-heavy `query` verb is priced by request
# rate with escalating Equihash (n=96 k=5) proofs (see the browse gate below,
# exercised by demo:browse).
# Queries: properties, availability, my_bookings
# Actions: reserve_room, confirm_booking, payment_setup

require "securerandom"

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
require Rails.root.join("lib/stub_psp")

# Inject the RLS DSL into ActiveRecord::Migration so that migrations can
# call `enable_rls_on TABLE do ... end` directly.
ActiveRecord::Migration.include(Kiosk::RLS::DSL)

# ── Browse-heavy PoW demo (KIOSK_POW_BROWSE_DEMO=1) ───────────────────────
#
# Hotel search is browse-heavy: an assistant comparing options runs many
# `availability` queries, and that is legitimate — indistinguishable from
# scraping by pattern alone. So this vertical does NOT treat browsing as
# suspicion. It PRICES BY REQUEST RATE (a coarse proxy for depth): the first
# few queries are free, then each extra query costs escalating proof-of-work
# (metered pricing, not a wall). A human's assistant pays a few
# seconds of compute to look deeper; a bulk scraper pays linearly and forever.
# (The offset/page-precise "metered pagination" variant is deferred;
# this rate-based form needs no change to the reputation Factors interface.)
#
# The rate is tracked per agent in-process (demo only — a real provider uses a
# shared counter / sliding window). EQUIHASH_BROWSE_PARAMS are small so each
# proof solves sub-second.
EQUIHASH_BROWSE_PARAMS = { n: 96, k: 5 }.freeze
HOTELING_FREE_BROWSES  = 3    # first N availability queries are free
HOTELING_RATE_STEP     = 2    # +1 proof per this many queries beyond the free tier
HOTELING_MAX_PROOFS    = 5

if ENV["KIOSK_POW_BROWSE_DEMO"] == "1"
  require "kiosk/pow/equihash"
  require "kiosk/reputation"
  Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

  HOTELING_BROWSE_COUNT = Hash.new(0)  # agent_id => availability queries so far

  # Priced-pagination policy: free below the allowance, then proof count rises
  # with the query rate. Only the `query` verb (browsing) is priced; run/pay
  # are never gated here.
  class HotelingBrowsePolicy < Kiosk::Reputation::Policy
    def initialize(params)
      @params = params
    end

    def challenge_for(identity:, verb:, factors:)
      return nil unless verb == :query
      rate = factors.request_rate_per_min.to_i
      return nil if rate <= HOTELING_FREE_BROWSES

      over  = rate - HOTELING_FREE_BROWSES
      count = [(over + HOTELING_RATE_STEP - 1) / HOTELING_RATE_STEP, HOTELING_MAX_PROOFS].min
      { alg: Kiosk::Pow::Equihash::NAME, params: @params, count: count }
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

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3004")
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  c.owner  = { name: "hoteling", support: "help@hoteling.app" }
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.0.md"
  c.skill_sha256 = "5331eed3f6ebd00b7c26ab903da81c49ef630c54132efbb376ec93a2cd124dea"

  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # The web-session channel for the account-binding surfaces (verify
  # page, link mint, unlink) — see lib/stub_user_idp.rb for the scope.
  c.user_idp = StubUserIdp.new

  c.payment_provider = StubPsp.new

  # ── Browse-heavy priced-pagination gate (KIOSK_POW_BROWSE_DEMO=1) ────────
  if ENV["KIOSK_POW_BROWSE_DEMO"] == "1"
    c.reputation_policy = HotelingBrowsePolicy.new(EQUIHASH_BROWSE_PARAMS)
    c.pow_secret        = ENV.fetch("KIOSK_POW_SECRET", "hoteling-demo-pow-secret")
    c.pow_ttl           = 300

    # Factors: count availability queries per agent in-process and report the
    # running total as the "rate". Only `query` is counted (browsing depth).
    c.reputation_factors = ->(identity:, verb:) {
      if verb == :query
        HOTELING_BROWSE_COUNT[identity.agent_id] += 1
      end
      Kiosk::Reputation::Factors.new(
        kyc_level: nil, settled_purchases_count: nil, settled_purchases_cents: nil,
        request_rate_per_min: HOTELING_BROWSE_COUNT[identity.agent_id],
        account_age_seconds: nil, dispute_count: nil, bad_proof_count: 0,
      )
    }
  end
end

# ─── Queries ────────────────────────────────────────────────────────────────

Kiosk::Server::Queries.register("properties",
  description: "Browse all available hotel properties") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, name, city FROM public.properties ORDER BY name"
  ).to_a
end

Kiosk::Server::Queries.register("availability",
  description: "Check room availability at a property for given dates",
  params: {
    property_id: "integer — property to check",
    check_in:    "date string YYYY-MM-DD",
    check_out:   "date string YYYY-MM-DD",
  }) do |params|
  conn = ActiveRecord::Base.connection
  prop_id   = params.fetch(:property_id)  { raise Kiosk::Server::Errors::BadRequest.new("missing field: property_id") }
  check_in  = params.fetch(:check_in)     { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_in") }
  check_out = params.fetch(:check_out)    { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_out") }
  conn.execute(<<~SQL).to_a
    SELECT rt.id, rt.name, rt.nightly_price_cents
    FROM public.room_types rt
    WHERE rt.property_id = #{conn.quote(prop_id.to_s)}::integer
    AND rt.id NOT IN (
      SELECT room_type_id FROM public.bookings
      WHERE property_id = #{conn.quote(prop_id.to_s)}::integer
        AND status IN ('reserved', 'confirmed')
        AND check_in < #{conn.quote(check_out.to_s)}::date
        AND check_out > #{conn.quote(check_in.to_s)}::date
    )
    ORDER BY rt.nightly_price_cents
  SQL
end

Kiosk::Server::Queries.register("my_bookings",
  description: "List this principal's hotel bookings (scoped to authenticated user)") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT b.id, b.property_id, b.room_type_id, b.check_in, b.check_out, b.total_cents, b.status " \
    "FROM public.bookings b " \
    "WHERE b.user_id = kiosk.current_user_id() " \
    "ORDER BY b.created_at DESC"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

# payment_setup — canonical skill Step 5 runs this unconditionally before
# `pay`. Mirrors the getgrocery registration shape; with StubPsp
# (no SetupIntent model) setup_required? is always false, so this is an
# immediate no-op success: {status: "ready"}.
Kiosk::Server::Actions.register("payment_setup",
  description: "Check whether the authenticated principal has a saved payment method. " \
               "Returns {status: \"ready\"} when the assistant can proceed to `pay`. " \
               "Returns {status: \"setup_required\", setup_url: \"…\"} when a hosted setup flow " \
               "must be completed by the human first. This demo's stub PSP needs no setup, " \
               "so it always returns ready. The assistant should call this before `pay`.",
  params: {}) do |_args|
  conn = ActiveRecord::Base.connection
  uid  = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  provider = Kiosk.configuration.payment_provider

  if provider.setup_required?(user_id: uid)
    { status: "setup_required", setup_url: provider.setup_url(user_id: uid) }
  else
    { status: "ready" }
  end
end

Kiosk::Server::Actions.register("reserve_room",
  description: "Reserve a room for the authenticated principal (creates a TTL hold)",
  params: {
    property_id:  "integer — property id",
    room_type_id: "integer — room type id",
    check_in:     "date string YYYY-MM-DD",
    check_out:    "date string YYYY-MM-DD",
  }) do |args|
  conn = ActiveRecord::Base.connection
  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?
  agent_id = conn.execute("SELECT kiosk.current_agent_id() AS aid").first["aid"]

  property_id  = args.fetch(:property_id)  { raise Kiosk::Server::Errors::BadRequest.new("missing field: property_id") }
  room_type_id = args.fetch(:room_type_id) { raise Kiosk::Server::Errors::BadRequest.new("missing field: room_type_id") }
  check_in     = args.fetch(:check_in)     { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_in") }
  check_out    = args.fetch(:check_out)    { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_out") }

  # Validate room_type belongs to property
  rt = conn.execute(
    "SELECT id, name, nightly_price_cents FROM public.room_types " \
    "WHERE id = #{conn.quote(room_type_id.to_s)}::integer " \
    "AND property_id = #{conn.quote(property_id.to_s)}::integer LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::BadRequest.new("room type not found for this property") if rt.nil?

  # Calculate total_cents (nights × nightly_price_cents)
  ci  = Date.parse(check_in.to_s)
  co  = Date.parse(check_out.to_s)
  raise Kiosk::Server::Errors::BadRequest.new("check_out must be after check_in") unless co > ci
  nights      = (co - ci).to_i
  total_cents = nights * rt["nightly_price_cents"].to_i

  conn.transaction do
    # INSERT booking row
    booking = conn.execute(<<~SQL).first
      INSERT INTO public.bookings (user_id, property_id, room_type_id, check_in, check_out, total_cents, status, created_at, updated_at)
      VALUES (
        #{conn.quote(uid)}::uuid,
        #{conn.quote(property_id.to_s)}::integer,
        #{conn.quote(room_type_id.to_s)}::integer,
        #{conn.quote(check_in.to_s)}::date,
        #{conn.quote(check_out.to_s)}::date,
        #{conn.quote(total_cents.to_s)}::integer,
        'reserved',
        now(), now()
      )
      RETURNING id
    SQL

    booking_id = booking["id"]

    # INSERT kiosk.reservations TTL row bound to the booking
    conn.execute(<<~SQL)
      INSERT INTO kiosk.reservations (user_id, agent_id, resource_kind, resource_id, args, expires_at)
      VALUES (
        #{conn.quote(uid)}::uuid,
        #{agent_id.nil? ? "NULL" : "#{conn.quote(agent_id.to_s)}::uuid"},
        'room_booking',
        #{conn.quote(booking_id.to_s)},
        '{}'::jsonb,
        now() + interval '15 minutes'
      )
    SQL

    {
      booking_id:  booking_id,
      total_cents: total_cents,
    }
  end
end

Kiosk::Server::Actions.register("confirm_booking",
  description: "Confirm a reserved booking (requires payment mandate referencing this booking)",
  params: {
    booking_id: "uuid — the booking to confirm",
  }) do |args|
  conn = ActiveRecord::Base.connection

  booking_id = args[:booking_id]
  if booking_id.nil? || booking_id.to_s.empty?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: booking_id")
  end

  conn.transaction do
    # ── Gate 1: booking belongs to principal AND status = 'reserved' ──────
    booking = conn.execute(
      "SELECT id FROM public.bookings " \
      "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id() " \
      "AND status = 'reserved' " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Forbidden.new("booking not found or not yours") if booking.nil?

    # ── Gate 2: settlement (capture receipt) whose cart references THIS booking
    booking_filter_json = [{ booking_id: booking_id.to_s }].to_json
    paid = conn.execute(
      "SELECT 1 AS ok " \
      "FROM kiosk.settlements pm " \
      "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
      "WHERE pm.user_id = kiosk.current_user_id() " \
      "AND cm.line_items @> #{conn.quote(booking_filter_json)}::jsonb " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Forbidden.new("no settlement for this booking") if paid.nil?

    # ── All gates passed: confirm ─────────────────────────────────────────
    confirmation_code = SecureRandom.uuid
    conn.execute(
      "UPDATE public.bookings SET status = 'confirmed', updated_at = now() " \
      "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id() " \
      "AND status = 'reserved'"
    )

    {
      booking_id:        booking_id,
      status:            "confirmed",
      confirmation_code: confirmation_code,
    }
  end
end
