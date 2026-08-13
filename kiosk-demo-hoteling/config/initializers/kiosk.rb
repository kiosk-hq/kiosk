# frozen_string_literal: true

# Kiosk-demo (hoteling-shape) configuration. Hotel booking with payment gate.
# No KYC, no hardware unlock. PoW is off by default; with
# KIOSK_POW_BROWSE_DEMO=1 the browse-heavy `query` verb is priced by request
# rate with escalating Equihash (n=96 k=5) proofs (see the browse gate below,
# exercised by demo:browse).
# Queries: properties, availability, my_bookings
# Actions: reserve_room, confirm_booking, payment_setup

require "securerandom"

# Env posture (ephemeral dev signing key, PoW secret, issuer, test flags) lives
# in config/environments/{development,test,production}.rb (K-650); this file
# reads the resolved values from Rails.configuration.x.kiosk.*.

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/stub_user_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")
require Rails.root.join("lib/uuid_check")
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

# ── Registration PoW gate — ALWAYS ON — POW-VERB-GATING (K-487)
#
# register is a verb like any other: a hotel provider prices fresh-identity
# minting (one Equihash proof) so a scraper renting throwaway agents pays at the
# door. Independent of the browse-rate gate above. Register is now uniformly
# tolled on every demo (no per-demo env flag to remember): it activates on
# code-deploy and can't be forgotten. Params follow KIOSK_POW_DIFFICULTY
# (hoteling ships low → n=96 k=5 sub-second). The gate requires the Equihash
# backend registered; the require + Backends.register run UNCONDITIONALLY here
# (both idempotent) so register-pow works regardless of KIOSK_POW_BROWSE_DEMO —
# else RegistrationPow.gate raises ConfigurationError at register.
HOTELING_REGISTRATION_POW_PARAMS = PowDifficulty.params
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

if ENV["KIOSK_POW_BROWSE_DEMO"] == "1"
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

# ── PoW HMAC secret (K-541/K-650) ───────────────────────────────────────────
# The HMAC key the engine signs every PoW challenge with. Required in
# production, stable (non-secret) default in dev/test — that posture lives in
# config/environments/*; here we only read the resolved value.
pow_secret = Rails.configuration.x.kiosk.pow_secret

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  # ── Issuer origin (K-510/K-650) ───────────────────────────────────────────
  # This operator's canonical origin — advertised in /.well-known/kiosk.json,
  # minted as the `iss` of every Kiosk JWT, and enforced as the `aud` of every
  # assistant proof-of-possession. Required in production, localhost default
  # in dev/test — the posture lives in config/environments/*.
  c.issuer = Rails.configuration.x.kiosk.issuer

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
  c.owner  = { name: "hoteling", support: "demo@kiosk.tech" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.10.md"
  c.skill_sha256 = "67265bd147ea3c6c32b240b1f2fc17f57ba17342770b989270ce34eb3f302a91"

  c.agent_idp = JwtOrStubIdp.new(stub: Rails.env.local? ? StubIdp.new : nil)
  # The web-session channel for the account-binding surfaces (verify
  # page, link mint, unlink) — see lib/stub_user_idp.rb for the scope.
  # DEV/TEST ONLY (K-555): the stub parses an UNSIGNED, self-asserted
  # `user:u-<uuid>` bearer into a human identity, so it is wired only under
  # Rails.env.local?; in production user_idp is nil and the binding surfaces
  # 401 until a real adapter (kiosk-user-idp-devise) is configured.
  c.user_idp = Rails.env.local? ? StubUserIdp.new : nil

  # The cashier check: ValidatingBookingProvider verifies the agent-signed
  # cart against OUR quote — currency (EUR), single booking reference, and the
  # total the operator quoted for that booking — before the wrapped StubPsp
  # captures anything. Monetary only: booking→payer ownership is enforced at
  # USE time (confirm_booking Gate-1), not here.
  c.payment_provider = ValidatingBookingProvider.new(StubPsp.new, currency: "eur")

  # ── Browse-heavy priced-pagination gate (KIOSK_POW_BROWSE_DEMO=1) ────────
  if ENV["KIOSK_POW_BROWSE_DEMO"] == "1"
    c.reputation_policy = HotelingBrowsePolicy.new(EQUIHASH_BROWSE_PARAMS)
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

  # ── Registration PoW gate — ALWAYS ON (register is uniformly tolled) ──────
  # Price fresh-identity minting: registering an agent costs ONE Equihash proof.
  # Independent of the browse gate above; pow_secret is set unconditionally so the
  # gate works even when KIOSK_POW_BROWSE_DEMO is off (RegistrationPow.gate raises
  # without it) — the browse-gate branch above shares this one assignment.
  c.registration_pow_count  = 1
  c.registration_pow_params = HOTELING_REGISTRATION_POW_PARAMS
  c.pow_secret              = pow_secret
end

# Amenity vocabulary — the closed set a property MAY offer. Shared by the
# search_hotels `amenity` filter enum (below) and the seeds (db/seeds.rb).
AMENITY_POOL = %w[wifi breakfast pool spa gym parking rooftop_bar
                  airport_shuttle sea_view pet_friendly restaurant hammam].freeze

# ─── Queries ────────────────────────────────────────────────────────────────

Kiosk::Server::Queries.register("properties",
  description: "Browse all available hotel properties. Each row carries a " \
               "`property_id`; pass it to availability (and reserve_room) as `property_id`.") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id AS property_id, name, city FROM public.properties ORDER BY name"
  ).to_a
end

Kiosk::Server::Queries.register("availability",
  description: "Check room availability at a property for given dates. Each row carries a " \
               "`room_type_id` (pass it to reserve_room as `room_type_id`, along with the " \
               "same `property_id`). nightly_price_cents is EUR cents per night — carts must " \
               "be signed in eur at the operator-quoted total (nights × nightly_price_cents)",
  params: {
    property_id: "integer — property to check (the `property_id` from a properties row)",
    check_in:    "date string YYYY-MM-DD",
    check_out:   "date string YYYY-MM-DD",
  }) do |params|
  conn = ActiveRecord::Base.connection
  prop_id   = params.fetch(:property_id)  { raise Kiosk::Server::Errors::BadRequest.new("missing field: property_id") }
  check_in  = params.fetch(:check_in)     { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_in") }
  check_out = params.fetch(:check_out)    { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_out") }
  rows = conn.execute(<<~SQL).to_a
    SELECT rt.id AS room_type_id, rt.name, rt.nightly_price_cents
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
  description: "List this principal's hotel bookings (scoped to authenticated user). " \
               "Each row carries a `booking_id`; pass it to confirm_booking as `booking_id`. " \
               "A confirmed row also carries the `confirmation_code` the hotel has on " \
               "file for it — the reference the guest gives at the desk — so it can be " \
               "read back at any time, not only in the confirm_booking response. " \
               "It is null until the booking is confirmed.") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT b.id AS booking_id, b.property_id, b.room_type_id, b.check_in, b.check_out, " \
    "b.total_cents, b.status, b.confirmation_code " \
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
               "address, amenities, and its room types (each carries a `room_type_id` for " \
               "reserve_room) with their nightly rates. This is " \
               "the \"search returns summaries, fetch detail on demand\" pattern — call it " \
               "for the one or few hotels the user is choosing between, not for the whole " \
               "result set. nightly_price_cents is EUR cents (carts are signed in eur). " \
               "DATES: pass check_in AND check_out (both, YYYY-MM-DD) to get only the room " \
               "types still FREE for those nights — the same rule `availability` applies and " \
               "reserve_room enforces. WITHOUT dates the room_types list is this property's " \
               "full CATALOGUE, not a statement about what is bookable: a room type listed " \
               "there may already be taken for your nights, and reserve_room will answer 409.",
  params: {
    property_id: "integer — the `property_id` from a search_hotels row",
    check_in:    "date string YYYY-MM-DD, optional — with check_out, list only room types free for these nights",
    check_out:   "date string YYYY-MM-DD, optional — with check_in, list only room types free for these nights",
  },
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      property_id: { type: "integer", description: "`property_id` from a search_hotels row." },
      check_in:    { type: "string", format: "date",
                     description: "Optional first night (YYYY-MM-DD); pass with check_out to list only free room types." },
      check_out:   { type: "string", format: "date",
                     description: "Optional checkout day (YYYY-MM-DD, exclusive); pass with check_in to list only free room types." },
    },
    required: ["property_id"],
  },
  example_params: { property_id: 4, check_in: "2026-09-01", check_out: "2026-09-04" },
  example_row: {
    property_id: 4, name: "Bosphorus Palace", neighbourhood: "Beşiktaş", stars: 5,
    address: "Çırağan Cd. 88, Beşiktaş, Istanbul",
    amenities: %w[wifi breakfast pool spa sea_view airport_shuttle],
    currency: "eur",
    room_types_scope: "free 2026-09-01..2026-09-04",
    check_in: "2026-09-01", check_out: "2026-09-04",
    room_types: [
      { room_type_id: 7, name: "Classic",   nightly_price_cents: 15000 },
      { room_type_id: 8, name: "Bosphorus", nightly_price_cents: 25000 },
    ],
  }) do |params|
  conn = ActiveRecord::Base.connection
  pid = params.fetch(:property_id) do
    raise Kiosk::Server::Errors::BadRequest.new("missing field: property_id")
  end

  # ── Optional date filter (K-690) ─────────────────────────────────────────
  # Without dates this query listed EVERY room type of a property with no
  # booking filter at all, so an assistant that went search → hotel_detail →
  # reserve_room (skipping `availability`) was reading a catalogue as if it
  # were an offer, and reserved rooms that were already sold. Given both dates
  # it now re-applies `availability`'s exclusion verbatim; given neither it says
  # so in the descriptor and in the response.
  ci_raw = params[:check_in].to_s.strip
  co_raw = params[:check_out].to_s.strip
  dated  = !ci_raw.empty? && !co_raw.empty?
  if !dated && (!ci_raw.empty? || !co_raw.empty?)
    raise Kiosk::Server::Errors::BadRequest.new(
      "check_in and check_out go together — pass both (YYYY-MM-DD) for a free-rooms " \
      "list, or neither for the property's full catalogue"
    )
  end
  if dated
    ci, co = begin
      [Date.parse(ci_raw), Date.parse(co_raw)]
    rescue ArgumentError, TypeError
      raise Kiosk::Server::Errors::BadRequest.new(
        "invalid check_in/check_out: #{ci_raw.inspect}/#{co_raw.inspect} — use YYYY-MM-DD"
      )
    end
    raise Kiosk::Server::Errors::BadRequest.new("check_out must be after check_in") unless co > ci
  end

  prop = conn.execute(
    "SELECT id, name, neighbourhood, stars, address, amenities " \
    "FROM public.properties WHERE id = #{conn.quote(pid.to_s)}::integer LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::NotFound.new("hotel not found: #{pid}") if prop.nil?

  free_only =
    if dated
      "AND id NOT IN (" \
      "SELECT room_type_id FROM public.bookings " \
      "WHERE property_id = #{conn.quote(pid.to_s)}::integer " \
      "AND status IN ('reserved', 'confirmed') " \
      "AND check_in < #{conn.quote(co.to_s)}::date " \
      "AND check_out > #{conn.quote(ci.to_s)}::date) "
    else
      ""
    end
  rooms = conn.execute(
    "SELECT id AS room_type_id, name, nightly_price_cents FROM public.room_types " \
    "WHERE property_id = #{conn.quote(pid.to_s)}::integer #{free_only}" \
    "ORDER BY nightly_price_cents"
  ).to_a

  # amenities is jsonb — normalise to a Ruby array regardless of driver decoding.
  amenities = prop["amenities"]
  amenities = JSON.parse(amenities) if amenities.is_a?(String)

  {
    property_id:      prop["id"],
    name:             prop["name"],
    neighbourhood:    prop["neighbourhood"],
    stars:            prop["stars"],
    address:          prop["address"],
    amenities:        amenities,
    currency:         "eur",
    # Says which of the two things the list is, so a reader of the response
    # alone (not the descriptor) cannot mistake a catalogue for an offer.
    room_types_scope: dated ? "free #{ci}..#{co}" : "catalogue (no dates given — not an availability statement)",
    check_in:         dated ? ci.to_s : nil,
    check_out:        dated ? co.to_s : nil,
    room_types:       rooms,
  }
end

# ─── Actions ────────────────────────────────────────────────────────────────

# payment_setup — canonical skill Step 5 runs this unconditionally before
# `pay`. Mirrors the getgrocery registration shape; with StubPsp
# (no SetupIntent model) setup_required? is always false, so this is an
# immediate no-op success: {status: "ready"}.
#
# POLL CADENCE + STOP CONDITION (K-477/K-595): the wire has no server→assistant
# push, so an assistant that ever DOES get a `setup_required` learns the human
# finished the hosted card entry ONLY by re-calling this. The descriptor
# therefore has to state a cadence AND a terminal stop condition — without one an
# agent invents its own and can poll forever if the human never completes the
# step. Stated even though this demo's StubPsp short-circuits it, so the
# PUBLISHED contract is the same across all three payment demos.
#
# The cadence here is the skill's, verbatim (skill.md Step 5: ~5 s for the first
# minute, then ~15 s, give up after ~5 minutes) — the skill is what assistants
# actually follow, so a descriptor that prescribes anything else is a second,
# losing instruction. And no CHECK COUNT is stated: a count is derived from the
# cadence and the horizon, so it silently goes wrong the moment either moves
# (the earlier "~60 checks" implied a flat 5 s cadence and was more than double
# what this schedule yields). The horizon is the number an assistant needs.
#
# NOTE getgrocery's descriptor also promises the setup_url is stable across polls
# (K-492 — a real-Stripe SetupIntent-reuse property). That promise is NOT
# repeated here: StubPsp mints no setup session at all, so there is nothing to be
# stable about and claiming it would be a claim about code this demo never runs.
Kiosk::Server::Actions.register("payment_setup",
  description: "Check whether the authenticated principal has a saved payment method. " \
               "Returns {status: \"ready\"} when the assistant can proceed to `pay`. " \
               "Returns {status: \"setup_required\", setup_url: \"…\"} when a hosted setup flow " \
               "must be completed by the human first — hand the setup_url to the human, wait for " \
               "them to finish, then call payment_setup again before paying. " \
               "This demo's stub PSP needs no setup, so it always returns ready. " \
               "The assistant should call this before `pay`. " \
               "POLLING: if you ever do get setup_required, re-check every ~5 seconds for the first " \
               "minute, then every ~15 seconds, while your human is at the hosted page, and GIVE UP " \
               "after about 5 minutes — tell your human the card setup is still not finished rather " \
               "than polling indefinitely; they can finish later and you re-check then.",
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
    # ── Finite inventory: the room-night must still be free (K-690) ─────────
    # `availability` (above) defines the invariant this action sells against —
    # a room type is offered only while no live booking overlaps the requested
    # nights — but nothing here re-applied it, so two assistants reading the
    # same availability page could both reserve and both PAY for one room, and
    # the operator would owe two guests one bed. Same three-part shape
    # atablefor's `book_table` uses, and for the same reason: a pre-check that
    # answers a clean 409 an assistant can act on, a database EXCLUDE
    # constraint that makes the race unrepresentable, and a rescue that turns
    # the lost race into that same 409. Nights are half-open — a checkout day
    # is the next guest's check-in day — which is exactly `availability`'s
    # `check_in < …check_out AND check_out > …check_in` test.
    clash = conn.execute(<<~SQL).first
      SELECT id FROM public.bookings
      WHERE room_type_id = #{conn.quote(room_type_id.to_s)}::integer
        AND status IN ('reserved', 'confirmed')
        AND check_in  < #{conn.quote(check_out.to_s)}::date
        AND check_out > #{conn.quote(check_in.to_s)}::date
      LIMIT 1
    SQL
    if clash
      raise Kiosk::Server::Errors::Conflict.new(
        "room type #{room_type_id} is already booked for #{check_in}..#{check_out} — " \
        "call availability again for the room types still free on those dates"
      )
    end

    # INSERT booking row
    booking =
      begin
        conn.execute(<<~SQL).first
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
      rescue ActiveRecord::ExclusionViolation
        # Lost the race for the same room-night — bookings_no_overlapping_room_nights
        # caught it. Same answer as the pre-check, so a concurrent caller and a
        # slow caller cannot tell the two apart.
        raise Kiosk::Server::Errors::Conflict.new(
          "room type #{room_type_id} is already booked for #{check_in}..#{check_out} — " \
          "call availability again for the room types still free on those dates"
        )
      end

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
  description: "Confirm a reserved booking (requires payment mandate referencing this booking). " \
               "Returns the `confirmation_code` the hotel stores against the booking — the " \
               "reference the guest gives at the desk. It is durable: the same code is listed " \
               "by my_bookings afterwards, and confirming again never mints a different one.",
  params: {
    booking_id: "uuid — the booking to confirm",
  }) do |args|
  conn = ActiveRecord::Base.connection

  booking_id = args[:booking_id]
  if booking_id.blank?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: booking_id")
  end
  # K-581/K-582: this id is cast `::uuid` below — a malformed one made Postgres
  # raise InvalidTextRepresentation, which is not a Kiosk error and so surfaced
  # as a raw 500 (leaking "invalid input syntax for type uuid") for what is
  # plainly a client mistake. Check the shape first, answer 400.
  unless UuidCheck.valid?(booking_id)
    raise Kiosk::Server::Errors::BadRequest.new(
      "booking_id #{booking_id.to_s.inspect} is not a uuid — pass the `booking_id` " \
      "that reserve_room returned (also listed by my_bookings)"
    )
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
    # K-698: the code is PERSISTED in the same UPDATE and read back out of it,
    # so what the assistant is handed is provably what the hotel stored. It used
    # to be a `SecureRandom.uuid` minted for the response only, against a table
    # with no such column — a booking reference the desk could never match.
    # COALESCE so an already-coded booking keeps its code: today Gate 1 above
    # makes a re-confirm a 403, but the reference has to be stable no matter
    # what that gate does later.
    confirmed = conn.execute(
      "UPDATE public.bookings " \
      "SET status = 'confirmed', " \
      "    confirmation_code = COALESCE(confirmation_code, #{conn.quote(SecureRandom.uuid)}), " \
      "    updated_at = now() " \
      "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id() " \
      "AND status = 'reserved' " \
      "RETURNING confirmation_code"
    ).first

    {
      booking_id:        booking_id,
      status:            "confirmed",
      confirmation_code: confirmed["confirmation_code"],
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
