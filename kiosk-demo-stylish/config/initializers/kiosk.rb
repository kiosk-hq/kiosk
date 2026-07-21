# frozen_string_literal: true

# Kiosk-demo (stylish — Combette-shape) configuration. Concrete values for
# the salon-booking reference shape: uuid users, JWT-or-stub IdP, one
# Action registered (book_appointment).

# ── Ephemeral dev signing key ────────────────────────────────────
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
require Rails.root.join("lib/stub_user_idp")
require Rails.root.join("lib/composite_user_idp")
require Rails.root.join("lib/pow_difficulty")
require "kiosk/user_identity_providers/devise"

# Registration PoW gate (KIOSK_POW_REGISTER_DEMO=1). A booking SaaS can price
# fresh-identity minting: registering an agent costs one Equihash proof
# (one PoW = Equihash — a metered toll). Params follow KIOSK_POW_DIFFICULTY
# (lib/pow_difficulty.rb): low (default) → n=96 k=5 sub-second; high → n=168 k=7
# (~10s / ~1.3 GiB). Unset = low, so the walkthrough/isolation flows and CI are
# unchanged; a deployer can set high to feel the toll. Off entirely unless
# KIOSK_POW_REGISTER_DEMO=1.
STYLISH_REGISTRATION_POW_PARAMS = PowDifficulty.params
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

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in v0.1 alpha). This demo runs WITHOUT RLS — isolation
  # is enforced at the app layer (see the migration and the query/Action
  # WHERE clauses) — so app_role and system_role are set to the same role
  # only to satisfy the config; no `enable_rls_on`/GRANT statements run here.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3001")
  # stylish is dual-audience: CUSTOMERS book (customer), salon STAFF manage
  # the calendar (owner / stylist). Staff roles are sourced from the
  # provider's own IdP (roles-from-IdP) — see the StubUserIdp and the
  # `salon_calendar` query below.
  c.roles  = %i[customer stylist owner]
  # Role pinned to every SELF-registered agent (agents cannot choose their
  # own). Staff assistants get their role indirectly, from the bound human's
  # IdP role at link time — never self-selected.
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. When
  # KIOSK_POW_DIFFICULTY=high, surface an honest "beware: intensive PoW" notice
  # here so an agent/reader sees the toll BEFORE it dials register (only shown
  # at high; stylish ships low so it is normally absent).
  c.owner  = { name: "Stylish (Kiosk demo)", support: "demo@kiosk.tech" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.2.md"
  c.skill_sha256 = "ba708c6234f277409653810f8ef4d3ea10679866e3fd57cf7cb9148b089065d4"

  # JwtOrStubIdp tries Kiosk-issued JWTs (kiosk-pop register/login output;
  # the account-binding token poll mints the same JWTs) first, then falls
  # back to StubIdp's bespoke `agent:u-…:a-…:r-…` shape. One endpoint
  # authenticates both for the demo.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # The provider's own human-session channels. A composite: the
  # role-carrying StubUserIdp (the salon SSO/Okta stand-in — an
  # `X-Staff-Session` header naming a staff member, whose staff_role becomes
  # the session role; walked by `rake demo:roles`) tried first, then the real
  # Devise/Warden session (the /users/sign_in cookie that approves links on
  # the verify page, mints link codes, unlinks, and drives the
  # manage-assistants page; walked by `rake demo:binding`).
  c.user_idp = CompositeUserIdp.new(
    StubUserIdp.new,
    Kiosk::UserIdentityProviders::Devise.new,
  )

  # Per-assistant spending cap: read the cap from
  # agents.spending_cap_cents (the column edited on the manage-assistants
  # page). window_days stays default nil = all-time cumulative spend.
  c.spending_cap = Kiosk::Server::ColumnSpendingCap.new

  # ── Registration PoW gate (active only when KIOSK_POW_REGISTER_DEMO=1) ───
  if ENV["KIOSK_POW_REGISTER_DEMO"] == "1"
    c.registration_pow_count  = 1
    c.registration_pow_params = STYLISH_REGISTRATION_POW_PARAMS
    c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET", "stylish-demo-pow-secret")
  end
end

# ─── Queries ────────────────────────────────────────────────────────────────

# salons — full salon catalogue; no per-user scoping, any authenticated
# principal may browse (mirrors the public SELECT policy previously in RLS).
Kiosk::Server::Queries.register("salons",
                                 description: "Browse the public salon catalogue",
                                 params: {}) do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, name FROM salons ORDER BY id"
  ).to_a
end

# my_appointments — per-user appointment list scoped by the session GUC.
# App-layer isolation: the agent supplies no filter; the WHERE is
# provider-controlled and cannot be bypassed by the caller.
Kiosk::Server::Queries.register("my_appointments",
                                 description: "List this principal's appointments (scoped to authenticated user via kiosk.current_user_id())",
                                 params: {}) do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, salon_id, slot FROM appointments " \
    "WHERE user_id = kiosk.current_user_id() " \
    "ORDER BY id"
  ).to_a
end

# salon_calendar — STAFF calendar, role-gated (roles-from-IdP).
# Reads kiosk.current_role() (the GUC set from the token's role claim, which a
# staff assistant inherited from the bound human's IdP role):
#
#   owner   → the WHOLE book: every appointment at the salon, plus a
#             revenue total (all chairs).
#   stylist → ONLY their own chairs: rows WHERE stylist_id =
#             kiosk.current_user_id(). A stylist's assistant cannot widen
#             this — the role rides the token, not the request args, and the
#             WHERE is provider-controlled.
#
# Any other role (or none) sees an empty calendar. The gate is un-bypassable:
# an agent can neither self-select `owner` at binding nor pass a wider filter.
STYLISH_APPOINTMENT_PRICE_CENTS = 6000 # flat demo price per chair, for the owner's revenue total
Kiosk::Server::Queries.register("salon_calendar",
                                 description: "Staff calendar — role-gated: owner sees the whole book + revenue, a stylist only their own chairs (role from the bound human's IdP)",
                                 params: {}) do |_params|
  role = ActiveRecord::Base.connection.execute(
    "SELECT kiosk.current_role() AS role"
  ).first["role"]

  scope =
    case role
    when "owner"   then "TRUE"                                    # the whole book
    when "stylist" then "stylist_id = kiosk.current_user_id()"    # only own chairs
    else "FALSE"                                                  # non-staff see nothing
    end

  rows = ActiveRecord::Base.connection.execute(
    "SELECT id, salon_id, stylist_id, slot FROM appointments " \
    "WHERE #{scope} ORDER BY slot"
  ).to_a

  # Owner also gets a revenue total across everything they can see.
  if role == "owner"
    rows << {
      "summary"       => "revenue",
      "appointments"  => rows.size,
      "revenue_cents" => rows.size * STYLISH_APPOINTMENT_PRICE_CENTS,
    }
  end
  rows
end

# ─── Actions ────────────────────────────────────────────────────────────────

# Register the demo Action. In production, providers use the full
# `Kiosk::Action` DSL (post-v0.1); for this demo a simple registered
# block is sufficient.
Kiosk::Server::Actions.register("book_appointment",
                                 description: "Book an appointment at a salon for the authenticated principal",
                                 params: {
                                   salon_id: "integer — id of the salon (from the `salons` query)",
                                   slot:     "string — appointment time as an ISO 8601 timestamp",
                                 }) do |args|
  # Identity is set via Kiosk::Server::SessionContext SET LOCAL —
  # current_user_id() helper returns the principal. ActiveRecord doesn't
  # have direct access; pull from PG.
  user_id = ActiveRecord::Base.connection.execute(
    "SELECT kiosk.current_user_id() AS uid"
  ).first["uid"]

  appointment = Appointment.create!(
    user_id:  user_id,
    salon_id: args[:salon_id],
    slot:     args[:slot],
  )

  { appointment_id: appointment.id, salon_id: appointment.salon_id, slot: appointment.slot.iso8601 }
end

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  require Rails.root.join("lib/demo_telemetry")
  STYLISH_VERB_MAP = {
    "book_appointment" => "booked",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: STYLISH_VERB_MAP,
  )
end
