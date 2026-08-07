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
require Rails.root.join("lib/validating_booking_provider")
require Rails.root.join("lib/pow_difficulty")

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
# shared counter / sliding window). EQUIHASH_BROWSE_PARAMS follow
# KIOSK_POW_DIFFICULTY (lib/pow_difficulty.rb): low (default) → n=96 k=5
# sub-second; high → n=168 k=7 (~10s / ~1.3 GiB). hoteling ships low; the knob
# is here for parity across the hosted apps. Unset = low.
EQUIHASH_BROWSE_PARAMS = PowDifficulty.params
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

  # UNIFORM-VALIDATION slice-1 (K-479): validate a PRESENT `pow` field against
  # the normative PoW schema at the wire choke point, so a malformed pow gets a
  # clear 400 bad_request (with a shape hint) instead of a silent re-issued 402
  # loop. Needs the json_schemer gem (in the Gemfile). Absent/valid pow paths
  # unchanged.
  c.validate_requests = true
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. A
  # "beware: intensive PoW" notice appears only when KIOSK_POW_DIFFICULTY=high
  # (hoteling ships low, so normally absent).
  c.owner  = { name: "hoteling", support: "help@hoteling.app" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.8.md"
  c.skill_sha256 = "7c3d06402bae212288c4538c1510f123652ffa5b2b07dbc4b79ee6871c45c931"

  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # The web-session channel for the account-binding surfaces (verify
  # page, link mint, unlink) — see lib/stub_user_idp.rb for the scope.
  c.user_idp = StubUserIdp.new

  # The cashier check: ValidatingBookingProvider verifies the agent-signed
  # cart against OUR quote — currency (EUR), single booking reference, and the
  # total the operator quoted for that booking — before the wrapped StubPsp
  # captures anything. Monetary only: booking→payer ownership is enforced at
  # USE time (confirm_booking Gate-1), not here.
  c.payment_provider = ValidatingBookingProvider.new(StubPsp.new, currency: "eur")

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

# Amenity vocabulary — the closed set a property MAY offer. Shared by the
# search_hotels `amenity` filter enum (below) and the seeds (db/seeds.rb).
AMENITY_POOL = %w[wifi breakfast pool spa gym parking rooftop_bar
                  airport_shuttle sea_view pet_friendly restaurant hammam].freeze

# ─── Queries ────────────────────────────────────────────────────────────────

Kiosk::Server::Queries.register("properties",
  description: "Browse all available hotel properties") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, name, city FROM public.properties ORDER BY name"
  ).to_a
end

Kiosk::Server::Queries.register("availability",
  description: "Check room availability at a property for given dates. " \
               "nightly_price_cents is EUR cents per night — carts must be signed in eur at " \
               "the operator-quoted total (nights × nightly_price_cents)",
  params: {
    property_id: "integer — property to check",
    check_in:    "date string YYYY-MM-DD",
    check_out:   "date string YYYY-MM-DD",
  }) do |params|
  conn = ActiveRecord::Base.connection
  prop_id   = params.fetch(:property_id)  { raise Kiosk::Server::Errors::BadRequest.new("missing field: property_id") }
  check_in  = params.fetch(:check_in)     { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_in") }
  check_out = params.fetch(:check_out)    { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_out") }
  rows = conn.execute(<<~SQL).to_a
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
  # Advertise the pricing currency so an external assistant knows to sign its
  # cart in EUR (the cashier check rejects any other currency at capture).
  rows.each { |r| r["currency"] = "eur" }
  rows
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

# ── search_hotels — paginated, multi-parameter search (T-042 / K-452) ────────
#
# The reference exemplar for the "~100 hotels would overwhelm an unpaginated
# list" case. Filters (all optional) narrow the ~100-property catalog; a small
# page (default 20) is returned with an opaque `next` cursor when more rows
# match, absent on the last page. An assistant should apply the human's stated
# constraints and page only if the human needs to see more.
HOTELING_SEARCH_PAGE = 20  # default page size (assistant may override via `limit`)
HOTELING_SEARCH_MAX  = 50  # cap so `limit` can't defeat pagination

Kiosk::Server::Queries.register("search_hotels",
  description: "Search Istanbul hotels with optional filters, returning a paginated " \
               "page of SUMMARY rows (one row per property, cheapest room's nightly " \
               "rate). Apply the user's stated constraints as filters; do not fetch " \
               "the whole catalogue. All filters are optional and AND together: " \
               "neighbourhood (exact area name), max_price_cents (cheapest room ≤ this, " \
               "EUR cents), min_stars (star rating ≥ this), amenity (property must offer " \
               "it). Page size defaults to 20 (override with limit, capped at 50); when " \
               "the response carries a top-level `next`, more hotels match — echo it back " \
               "verbatim as `cursor` to fetch the following page, and keep paging until " \
               "`next` is absent. from_price_cents is EUR cents (carts are signed in eur). " \
               "Each row carries a `property_id`; pass it to hotel_detail as `property_id` " \
               "for the full property (rooms, amenities, address).",
  params: {
    neighbourhood:  "string, optional — exact area, e.g. \"Kadıköy\"",
    max_price_cents: "integer, optional — cheapest room's nightly rate ≤ this (EUR cents)",
    min_stars:      "integer 1..5, optional — star rating floor",
    amenity:        "string, optional — property must offer this amenity",
    limit:          "integer, optional — page size (default 20, max 50)",
    cursor:         "string, optional — opaque `next` from a prior page, echoed verbatim",
  },
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      neighbourhood: {
        type: "string",
        enum: %w[Sultanahmet Beyoğlu Kadıköy Beşiktaş Şişli Fatih
                 Üsküdar Galata Taksim Ortaköy Bakırköy Nişantaşı],
        description: "Exact Istanbul area name.",
      },
      max_price_cents: { type: "integer", minimum: 0, description: "Cheapest room ≤ this, EUR cents." },
      min_stars:       { type: "integer", minimum: 1, maximum: 5, description: "Star-rating floor." },
      amenity:         { type: "string", enum: AMENITY_POOL, description: "Property must offer this amenity." },
      limit:           { type: "integer", minimum: 1, maximum: HOTELING_SEARCH_MAX,
                         default: HOTELING_SEARCH_PAGE, description: "Page size." },
      cursor:          { type: "string", description: "Opaque `next` cursor from a prior page." },
    },
    required: [],
  },
  example_params: { neighbourhood: "Beşiktaş", min_stars: 4, max_price_cents: 20000, limit: 20 },
  example_row: {
    property_id: 4, name: "Bosphorus Palace", neighbourhood: "Beşiktaş", stars: 5,
    from_price_cents: 15000, currency: "eur", room_type_count: 2,
  }) do |params|
  conn = ActiveRecord::Base.connection

  limit = params[:limit].to_s.strip.empty? ? HOTELING_SEARCH_PAGE : params[:limit].to_i
  limit = HOTELING_SEARCH_PAGE if limit <= 0
  limit = HOTELING_SEARCH_MAX if limit > HOTELING_SEARCH_MAX
  offset = Kiosk::Server::Cursor.decode_offset(params[:cursor])

  where = ["1=1"]
  if (nb = params[:neighbourhood]) && !nb.to_s.strip.empty?
    where << "p.neighbourhood = #{conn.quote(nb.to_s)}"
  end
  if (ms = params[:min_stars]) && !ms.to_s.strip.empty?
    where << "p.stars >= #{conn.quote(ms.to_i.to_s)}::integer"
  end
  if (am = params[:amenity]) && !am.to_s.strip.empty?
    where << "p.amenities @> #{conn.quote([am.to_s].to_json)}::jsonb"
  end
  # Cheapest nightly rate per property (the summary price the row advertises).
  price_floor = "(SELECT MIN(rt.nightly_price_cents) FROM public.room_types rt WHERE rt.property_id = p.id)"
  if (mp = params[:max_price_cents]) && !mp.to_s.strip.empty?
    where << "#{price_floor} <= #{conn.quote(mp.to_i.to_s)}::integer"
  end

  # Fetch limit+1 to detect a following page without a second COUNT query.
  sql = <<~SQL
    SELECT p.id AS property_id, p.name, p.neighbourhood, p.stars,
           #{price_floor} AS from_price_cents,
           (SELECT COUNT(*) FROM public.room_types rt WHERE rt.property_id = p.id) AS room_type_count
    FROM public.properties p
    WHERE #{where.join(" AND ")}
    ORDER BY p.stars DESC, from_price_cents ASC, p.id ASC
    LIMIT #{limit + 1} OFFSET #{offset}
  SQL
  rows = conn.execute(sql).to_a

  has_more = rows.length > limit
  rows = rows.first(limit)
  rows.each { |r| r["currency"] = "eur" }
  next_cursor = has_more ? Kiosk::Server::Cursor.encode_offset(offset + limit) : nil

  Kiosk::Server::Page.new(rows: rows, next_cursor: next_cursor)
end

# ── hotel_detail — fetch ONE property by id (search→summaries, fetch on demand)
Kiosk::Server::Queries.register("hotel_detail",
  description: "Fetch the full detail for ONE hotel by its `property_id` (the same " \
               "`property_id` a search_hotels row carries): name, neighbourhood, stars, " \
               "address, amenities, and every room type with its nightly rate. This is " \
               "the \"search returns summaries, fetch detail on demand\" pattern — call it " \
               "for the one or few hotels the user is choosing between, not for the whole " \
               "result set. nightly_price_cents is EUR cents (carts are signed in eur).",
  params: {
    property_id: "integer — the `property_id` from a search_hotels row",
  },
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      property_id: { type: "integer", description: "`property_id` from a search_hotels row." },
    },
    required: ["property_id"],
  },
  example_params: { property_id: 4 },
  example_row: {
    property_id: 4, name: "Bosphorus Palace", neighbourhood: "Beşiktaş", stars: 5,
    address: "Çırağan Cd. 88, Beşiktaş, Istanbul",
    amenities: %w[wifi breakfast pool spa sea_view airport_shuttle],
    currency: "eur",
    room_types: [
      { id: 7, name: "Classic",   nightly_price_cents: 15000 },
      { id: 8, name: "Bosphorus", nightly_price_cents: 25000 },
    ],
  }) do |params|
  conn = ActiveRecord::Base.connection
  pid = params.fetch(:property_id) do
    raise Kiosk::Server::Errors::BadRequest.new("missing field: property_id")
  end

  prop = conn.execute(
    "SELECT id, name, neighbourhood, stars, address, amenities " \
    "FROM public.properties WHERE id = #{conn.quote(pid.to_s)}::integer LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::NotFound.new("hotel not found: #{pid}") if prop.nil?

  rooms = conn.execute(
    "SELECT id, name, nightly_price_cents FROM public.room_types " \
    "WHERE property_id = #{conn.quote(pid.to_s)}::integer ORDER BY nightly_price_cents"
  ).to_a

  # amenities is jsonb — normalise to a Ruby array regardless of driver decoding.
  amenities = prop["amenities"]
  amenities = JSON.parse(amenities) if amenities.is_a?(String)

  {
    property_id:   prop["id"],
    name:          prop["name"],
    neighbourhood: prop["neighbourhood"],
    stars:         prop["stars"],
    address:       prop["address"],
    amenities:     amenities,
    currency:      "eur",
    room_types:    rooms,
  }
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
  description: "Reserve a room for the authenticated principal (creates a TTL hold). " \
               "To pay, sign your AP2 cart mandate in EUR at the quoted total_cents with a " \
               "line_item that references the returned booking_id; the operator verifies " \
               "currency and total against its quote before charging (the result carries a pay_hint)",
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
      booking_id:          booking_id,
      total_cents:         total_cents,
      currency:            "eur",
      nights:              nights,
      nightly_price_cents: rt["nightly_price_cents"].to_i,
      pay_hint:            "pay in EUR with a cart mandate whose total_amount_cents == #{total_cents} " \
                           "and whose line_items reference this booking: one " \
                           "{\"sku\", \"qty\": #{nights}, \"price_cents\": #{rt["nightly_price_cents"]}, " \
                           "\"booking_id\": \"#{booking_id}\"} entry — the operator verifies currency and " \
                           "total against its quote before charging",
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

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  require Rails.root.join("lib/demo_telemetry")
  HOTELING_VERB_MAP = {
    "reserve_room"    => "reserved",
    "confirm_booking" => "booked",
    "payment_setup"   => "ran",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: HOTELING_VERB_MAP,
  )
end
