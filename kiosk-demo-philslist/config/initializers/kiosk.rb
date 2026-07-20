# frozen_string_literal: true

# Kiosk-demo configuration — philslist, a NON-COMMERCE classifieds board.
#
# The whole point of this demo: the same four-verb wire the commerce demos use
# for money carries a services/data surface with NO payment at all. There is NO
# `payment_provider` here, so `capabilities` computes to schema/query/run and
# DROPS `pay` — `/.well-known/kiosk.json`, `agents.json` and
# `agents.txt` all advertise no payments. That absence is the not-only-commerce
# proof (`demo:schema` asserts it).

# ── Ephemeral dev signing key ────────────────────────────────────
# JWT / register / binding flows need a signing key. In development or test, if
# none is provided, self-provision an EPHEMERAL RSA key so `demo:setup` and the
# flows run out-of-the-box. Never do this in production — a real key must be set.
if ENV["KIOSK_SIGNING_KEY_B64"].nil? && ENV["KIOSK_SIGNING_KEY_PEM"].nil? && Rails.env.local?
  require "openssl"
  require "base64"
  ENV["KIOSK_SIGNING_KEY_B64"] = Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)
  warn "[kiosk] WARNING: generated an EPHEMERAL signing key (#{Rails.env}); set KIOSK_SIGNING_KEY_B64/PEM for a stable key."
end

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require "kiosk/user_identity_providers/devise"

# Registration PoW gate (KIOSK_POW_REGISTER_DEMO=1). With no payment gate, the
# optional registration PoW toll is the defense of a FREE board against
# spam-listing bots — same feature the commerce demos price fresh-identity
# minting with, new meaning. Small demo params solve sub-second. Off by default
# so the walkthrough/isolation/binding flows are unchanged.
PHILSLIST_REGISTRATION_POW_PARAMS = { n: 96, k: 5 }.freeze
if ENV["KIOSK_POW_REGISTER_DEMO"] == "1"
  require "kiosk/pow/equihash"
  require "kiosk/reputation"
  Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
end

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no role
  # separation in v0.1 alpha). This demo runs WITHOUT RLS — isolation is
  # enforced at the app layer (the migration + the query/Action WHERE clauses)
  # — so app_role and system_role are set to the same role only to satisfy the
  # config; no enable_rls_on / GRANT statements run here.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3001")
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  c.owner  = { name: "philslist (Kiosk demo)", support: "demo@kiosk.tech" }
  # Pin the universal skill (immutable versioned file on kiosk.tech), like the
  # sibling demos — the skill-pin guard validates this against the real file.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.2.md"
  c.skill_sha256 = "ba708c6234f277409653810f8ef4d3ea10679866e3fd57cf7cb9148b089065d4"

  # ── NO payment_provider ──────────────────────────────────────────────────
  # This is deliberate and load-bearing: with no AP2 provider configured,
  # `pay` drops out of `capabilities` and the discovery documents carry no
  # payments block. philslist is a classifieds board — it takes no money.

  # JwtOrStubIdp tries Kiosk-issued JWTs (register/login output; the
  # account-binding token poll mints the same JWTs) first, then falls back to
  # StubIdp's bespoke `agent:u-…:a-…:r-…` shape. One endpoint authenticates
  # both for the demo.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # The provider's own web-session channel (Devise/Warden): authenticates the
  # approving human on the account-binding surfaces — the device verify page,
  # link-code mint, unlink, and the manage-assistants page. Walked by
  # `rake demo:binding`.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new

  # ── Registration PoW gate (active only when KIOSK_POW_REGISTER_DEMO=1) ───
  if ENV["KIOSK_POW_REGISTER_DEMO"] == "1"
    c.registration_pow_count  = 1
    c.registration_pow_params = PHILSLIST_REGISTRATION_POW_PARAMS
    c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET", "philslist-demo-pow-secret")
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# The authenticated principal (accounts.id). Identity is set via
# Kiosk::Server::SessionContext SET LOCAL, so current_user_id() resolves it.
# ActiveRecord has no direct access — pull it from PG.
def philslist_current_user_id
  ActiveRecord::Base.connection.select_value("SELECT kiosk.current_user_id()")
end

# The acting agent_id as a plain STRING (attribution for created_by_agent_id).
# Read the raw GUC — NOT kiosk.current_agent_id(), which casts to ::uuid and so
# would fail for the demo's stub tokens (agent_id like "alice-isolation").
# Returns nil for the human web surface (no agent) and for uuid or stub agents.
def philslist_current_agent_id
  ActiveRecord::Base.connection.select_value(
    "SELECT NULLIF(current_setting('app.current_agent_id', true), '')",
  )
end

# ─── Queries (the `query` verb) ───────────────────────────────────────────────

# browse_listings — the OPEN board. Any authenticated principal sees ALL
# matching listings across ALL owners (no owner_id filter). Optional
# category_slug + keyword filters; status clamps to open|closed (defaults open).
# All caller input is passed through conn.quote (parameterized ILIKE on
# title/body) — no raw interpolation (raw-pipe hygiene, the sibling-demo
# quoting pattern).
Kiosk::Server::Queries.register(
  "browse_listings",
  description: "Browse the public classifieds board across all sellers. Optional " \
               "category_slug and keyword filters; status defaults to open.",
  params: {
    category_slug: "string (optional) — restrict to one category (a listing's category_slug)",
    keyword:       "string (optional) — case-insensitive match on title or body",
    status:        "string (optional) — 'open' (default) or 'closed'",
  },
) do |params|
  conn = ActiveRecord::Base.connection

  status = params[:status].to_s
  status = "open" unless Listing::STATUSES.include?(status)

  sql = +<<~SQL
    SELECT l.id, l.title, l.body, l.price_text, c.slug AS category_slug,
           l.status, u.email AS owner_handle
      FROM listings l
      JOIN categories c ON c.id = l.category_id
      JOIN users u ON u.id = l.owner_id
     WHERE l.status = #{conn.quote(status)}
  SQL

  if params[:category_slug] && !params[:category_slug].to_s.empty?
    sql << " AND c.slug = #{conn.quote(params[:category_slug].to_s)}"
  end
  if params[:keyword] && !params[:keyword].to_s.empty?
    like = conn.quote("%#{params[:keyword]}%")
    sql << " AND (l.title ILIKE #{like} OR l.body ILIKE #{like})"
  end
  sql << " ORDER BY l.created_at DESC, l.id"

  conn.execute(sql).to_a
end

# my_listings — per-identity: the caller's OWN listings only. Caller supplies no
# filter; the WHERE is provider-controlled and un-bypassable (the saas
# my_appointments pattern).
Kiosk::Server::Queries.register(
  "my_listings",
  description: "List the listings owned by the authenticated principal " \
               "(scoped to kiosk.current_user_id()).",
  params: {},
) do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT l.id, l.title, l.price_text, l.status, c.slug AS category_slug " \
    "FROM listings l JOIN categories c ON c.id = l.category_id " \
    "WHERE l.owner_id = kiosk.current_user_id() " \
    "ORDER BY l.created_at DESC, l.id",
  ).to_a
end

# ─── Actions (the `run` verb) ─────────────────────────────────────────────────

# post_listing — create a listing under the AUTHENTICATED principal. Any
# agent-supplied owner_id in args is IGNORED (the forged-principal beat):
# owner_id is read from kiosk.current_user_id(). created_by_agent_id records the
# acting agent from the token (attribution).
Kiosk::Server::Actions.register(
  "post_listing",
  description: "Post a new classifieds listing owned by the authenticated principal.",
  params: {
    category_slug: "string (required) — the section to post in (see browse_listings)",
    title:         "string (required) — short headline",
    body:          "string (required) — the listing description",
    price_text:    "string (optional) — free-form display price, e.g. '1500 TL' or 'free'",
  },
) do |args|
  owner_id = philslist_current_user_id
  category = Category.find_by!(slug: args[:category_slug])

  listing = Listing.create!(
    owner_id:            owner_id,       # forged args[:owner_id] never consulted
    category:            category,
    title:               args[:title],
    body:                args[:body],
    price_text:          args[:price_text],
    status:              "open",
    created_by_agent_id: philslist_current_agent_id,
  )

  { listing_id: listing.id, status: listing.status }
end

# edit_listing — OWNER-ONLY. UPDATE … WHERE id AND owner_id =
# kiosk.current_user_id(); zero rows affected → 403 (return forbidden, not
# not-found, so cross-owner probing can't enumerate which ids exist).
Kiosk::Server::Actions.register(
  "edit_listing",
  description: "Edit one of the authenticated principal's own listings " \
               "(owner-only; editing another owner's listing is forbidden).",
  params: {
    listing_id: "uuid (required) — the listing to edit",
    title:      "string (optional) — new headline",
    body:       "string (optional) — new description",
    price_text: "string (optional) — new display price",
  },
) do |args|
  conn = ActiveRecord::Base.connection

  # Only the columns the caller supplied are updated; each value is quoted
  # updated_at always bumps so a no-op patch still verifies ownership.
  set_fragments = ["updated_at = now()"]
  %i[title body price_text].each do |col|
    set_fragments << "#{col} = #{conn.quote(args[col])}" if args.key?(col)
  end

  sql = "UPDATE listings SET #{set_fragments.join(', ')} " \
        "WHERE id = #{conn.quote(args[:listing_id].to_s)}::uuid " \
        "AND owner_id = kiosk.current_user_id() RETURNING id"
  rows = conn.execute(sql)

  if rows.ntuples.zero?
    raise Kiosk::Server::Errors::Forbidden.new(
      "listing not owned by the authenticated principal",
      hint: "You may only edit your own listings.",
    )
  end

  { listing_id: args[:listing_id], updated: true }
end

# close_listing — OWNER-ONLY, same owner-scoped WHERE; zero rows → 403.
Kiosk::Server::Actions.register(
  "close_listing",
  description: "Close one of the authenticated principal's own listings " \
               "(owner-only; closing another owner's listing is forbidden).",
  params: {
    listing_id: "uuid (required) — the listing to close",
  },
) do |args|
  conn = ActiveRecord::Base.connection
  rows = conn.execute(
    "UPDATE listings SET status = 'closed', updated_at = now() " \
    "WHERE id = #{conn.quote(args[:listing_id].to_s)}::uuid " \
    "AND owner_id = kiosk.current_user_id() RETURNING id",
  )

  if rows.ntuples.zero?
    raise Kiosk::Server::Errors::Forbidden.new(
      "listing not owned by the authenticated principal",
      hint: "You may only close your own listings.",
    )
  end

  { listing_id: args[:listing_id], status: "closed" }
end

# ── Live-activity telemetry (T-032 §4) — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  require Rails.root.join("lib/demo_telemetry")
  PHILSLIST_VERB_MAP = {
    "post_listing"  => "ordered",
    "edit_listing"  => "ran",
    "close_listing" => "cancelled",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: PHILSLIST_VERB_MAP,
  )
end
