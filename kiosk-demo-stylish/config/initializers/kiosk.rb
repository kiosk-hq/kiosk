# frozen_string_literal: true

# Kiosk-demo (stylish — Combette-shape) configuration. Concrete values for
# the salon-booking reference shape: uuid users, JWT-or-stub IdP, five queries
# and one action, all of them ordinary Rails controllers named below.

# Env posture (ephemeral dev signing key, PoW secret, issuer, test flags) lives
# in config/environments/{development,test,production}.rb (K-650); this file
# reads the resolved values from Rails.configuration.x.kiosk.*.

require "kiosk/user_identity_providers/devise"

# Registration PoW gate — ALWAYS ON. A booking SaaS prices fresh-identity
# minting: registering an agent costs one Equihash proof (one PoW = Equihash — a
# metered toll). Register is now uniformly tolled on every demo (no per-demo env
# flag to remember): it activates on code-deploy and can't be forgotten. Params
# follow KIOSK_POW_DIFFICULTY (app/services/pow_difficulty.rb): low (default) → n=96 k=5
# sub-second; high → n=168 k=7 (~10s / ~1.3 GiB). Unset = low, so the
# walkthrough/isolation flows and CI stay fast; a deployer can set high to feel
# the toll. The prerequisites below MUST run unconditionally, else
# RegistrationPow.gate raises ConfigurationError at register.
STYLISH_REGISTRATION_POW_PARAMS = PowDifficulty.params
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

# ── PoW HMAC secret (K-541/K-650) ───────────────────────────────────────────
# The HMAC key the engine signs every PoW challenge with. Required in
# production, stable (non-secret) default in dev/test — that posture lives in
# config/environments/*; here we only read the resolved value.
pow_secret = Rails.configuration.x.kiosk.pow_secret

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  # ── Where the wire verbs live (T-053 mixin / T-057) ────────────────────────
  # The queries and actions are ordinary Rails controllers under
  # app/controllers/kiosk/ — `include Kiosk::Query` / `include Kiosk::Action`,
  # class-level macros, plain `render json:`. Nothing about them belongs in an
  # initializer, and nothing about them is here: this line only NAMES them, and
  # the engine loads and registers them (once in production, again after every
  # reload in development, so an edited/added/removed verb needs no restart).
  c.handlers = %w[Kiosk::FrontDeskController Kiosk::AppointmentsController]

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in this demo). This demo runs WITHOUT RLS — isolation
  # is enforced at the app layer (see the migration and the WHERE clauses in
  # the two handler controllers) — so app_role and system_role are set to the
  # same role only to satisfy the config; no `enable_rls_on`/GRANT statements
  # run here.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  # ── Issuer origin (K-510/K-650) ───────────────────────────────────────────
  # This operator's canonical origin — advertised in /.well-known/kiosk.json,
  # minted as the `iss` of every Kiosk JWT, and enforced as the `aud` of every
  # assistant proof-of-possession. Required in production, localhost default
  # in dev/test — the posture lives in config/environments/*.
  c.issuer = Rails.configuration.x.kiosk.issuer

  # UNIFORM-VALIDATION slice-1 (K-479): validate the proof(s) parsed from the
  # `Kiosk-PoW` request header (ADR-0022) against the normative PoW schema at
  # the wire choke point, so a malformed proof gets a clear 400 bad_request
  # (with a shape hint) instead of a silent re-issued 402 loop. There is no
  # `pow` body field to validate — the header is the only channel. Needs the
  # json_schemer gem (in the Gemfile). Absent/valid proofs unchanged.
  c.validate_requests = true

  # T-068 slice 3: every query/action answer is validated against the
  # `output_schema` that verb declares, and a mismatch is a loud 500 rather
  # than a lie shipped to an assistant. A DEVELOPMENT/CI assertion, not a
  # request check — nothing a caller sends can trigger it — and it is what
  # makes this demo's own CI task list a per-verb conformance proof of the
  # descriptors rather than a smoke test.
  c.validate_responses = true
  # stylish is dual-audience: VISITORS book a service off the menu (customer),
  # salon STAFF view the forecasted revenue (owner). The owner role is sourced
  # from the provider's own IdP (roles-from-IdP) — see `User#kiosk_role`, the
  # `c.user_idp` wiring below, and the `salon_calendar` query in
  # Kiosk::FrontDeskController. (No stylist roster
  # — the menu is evergreen and infinite-capacity, so there is nothing
  # per-stylist to scope.)
  c.roles  = %i[customer owner]
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
  c.skill_url    = "https://kiosk.tech/skill-v0.4.2.md"
  c.skill_sha256 = "f2cab5f4664ac697ce8c9a18582924447ec9097f240bac3e32ca2a8b2bf2cfed"

  # ── NO c.agent_idp ───────────────────────────────────────────────────────
  # Deliberate, and the point of the line's absence (T-104). An assistant
  # authenticates with the kiosk-pop JWT this very engine minted at
  # `/kiosk/auth/register`, `/auth/login` or the binding ceremony — and the
  # engine already ships the adapter that verifies its own tokens:
  # `IdentityResolution.agent_idp` falls back to
  # `Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp` when nothing is
  # configured. This demo used to override it with a hand-copied composite that
  # re-implemented the JWT half (more loosely — it never checked `iss`) in
  # order to bolt on a dev-only parser turning a self-asserted
  # `agent:u-…:a-…:r-…` string into an identity at any role. Both are gone.
  # SET THIS only to front an EXTERNAL agent-identity issuer (Entra Agent ID,
  # Okta, an ID-JAG-style broker) by subclassing
  # `Kiosk::AgentIdentityProviders::Base` — whose one hard constraint is that
  # the `agent_id` you return must be a UUID (K-830).
  # The provider's own web-session channel (Devise/Warden): the /users/sign_in
  # cookie that approves links on the verify page, mints link codes, unlinks,
  # and drives the manage-assistants page. ONE channel in every environment
  # (T-066): the role-carrying `X-Staff-Session` stand-in that used to sit in
  # front of it is gone, and with it the composite that existed only to hold
  # the two.
  #
  # ROLES-FROM-IdP SURVIVES THE DELETION, and this is the seam worth reading:
  # the salon's role never came from the stand-in's header, it came from the
  # provider's own users table. The Devise adapter asks the User model for
  # `#kiosk_role`, which returns the staff member's `staff_role` — so an OWNER
  # who signs in at /users/sign_in mints link codes as `owner`, kiosk-server
  # captures that role onto the link row (AuthController#link →
  # LinkCode.mint(requested_role:)), and the assistant that redeems it inherits
  # it. Walked by `rake demo:roles`.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  # Where the engine bounces an UNAUTHENTICATED browser visitor to the
  # manage-assistants page (this app's Devise sign-in). The engine stays
  # IdP-neutral, so the sign-in URL is supplied here; without it the page
  # would render a bare 401 (MANAGE-PAGE-UNAUTH-UX).
  c.sign_in_path = "/users/sign_in"

  # Per-assistant spending cap: read the cap from
  # agents.spending_cap_cents (the column edited on the manage-assistants
  # page). window_days stays default nil = all-time cumulative spend.
  c.spending_cap = Kiosk::Server::ColumnSpendingCap.new

  # ── Registration PoW gate — ALWAYS ON (register is uniformly tolled) ──────
  c.registration_pow_count  = 1
  c.registration_pow_params = STYLISH_REGISTRATION_POW_PARAMS
  c.pow_secret              = pow_secret
end

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  STYLISH_VERB_MAP = {
    "book_appointment" => "booked",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: STYLISH_VERB_MAP,
  )
end
