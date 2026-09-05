# frozen_string_literal: true

# Kiosk-demo (stylish — Combette-shape) configuration. Concrete values for
# the salon-booking reference shape: uuid users, the engine's own agent IdP, five queries
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
# sub-second; high → n=168 k=7 (~1.3 GiB per proof, and ~10s on the reference
# numpy solver as measured on one M-series laptop core). Unset = low, so the
# walkthrough/isolation flows and CI stay fast; a deployer can set high to feel
# the toll. The prerequisites below MUST run unconditionally, else
# RegistrationPow.gate raises ConfigurationError at register.
STYLISH_REGISTRATION_POW_PARAMS = PowDifficulty.params
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

# ── PoW HMAC secret ─────────────────────────────────────────────────────────
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
  # app/controllers/kiosk/ — `include Kiosk::Handler`, class-level macros (`kind`
  # says which verb reaches each one), plain `render json:`. Nothing about them belongs in an
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
  # ── Postgres role names ──────────────────────────────────────────────────
  # Resolved in config/environments/*, like every other env input; read here.
  c.app_role    = Rails.configuration.x.kiosk.app_role
  c.system_role = Rails.configuration.x.kiosk.system_role

  # ── Issuer origin ─────────────────────────────────────────────────────────
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
  # TWO roles, so this origin is the one in the fleet where role totality has
  # teeth: `User#kiosk_role` MUST answer a declared role for EVERY human, never
  # nil. A role for staff and nothing for customers is not a supported
  # configuration — the ceremony would leave an `owner` assistant at `owner`
  # while its principal became a customer (kiosk.tech `protocol.md` §6.3).
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
  c.skill_url    = "https://kiosk.tech/skill-v0.4.12.md"
  c.skill_sha256 = "7d5be9bf841f8e05fd67b62b60d140fab584de373f8e28944298c93139f9a9ca"

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

  # ── NO spending_cap seam, and the reason is the same as the NO
  #    payment_provider one ──────────────────────────────────────────────────
  # `config.spending_cap` is read at exactly one site — `Executor#verb_pay`'s
  # mandate chain — and since K-800 the provider check runs FIRST, so a `pay`
  # here is `403 no payment_provider configured` before a cart exists. stylish
  # configures no payment_provider (this salon takes payment in the chair), so a
  # seam set here could never be consulted: it was, until K-989 measured it.
  # What stylish DOES demonstrate is the governance surface above the cap — the
  # manage-assistants page writes `agents.spending_cap_cents`, which
  # `demo:binding` asserts end to end — and that is deliberate: a human sets the
  # policy on the page whether or not this origin is the one that charges.
  # An origin that both charges and caps sets `c.spending_cap =
  # Kiosk::Server::ColumnSpendingCap.new` beside its `payment_provider`.

  # ── Registration PoW gate — ALWAYS ON (register is uniformly tolled) ──────
  c.registration_pow_count  = 1
  c.registration_pow_params = STYLISH_REGISTRATION_POW_PARAMS
  c.pow_secret              = pow_secret

  # ── One process today. Before this origin ever runs two, read this ───────
  # `pow_spent_store` is left at its IN-PROCESS default here, and that is
  # correct only because each demo origin runs a SINGLE process. Two Puma
  # workers, two dynos or two pods — or a rolling deploy where the old and the
  # new process overlap for a minute — each keep their OWN spent-id set, so
  # one proof is accepted once PER PROCESS and the toll above is silently
  # discounted by however many processes are running.
  #
  # WHY THIS IS WRITTEN DOWN RATHER THAN DETECTED: a replayed proof is not an
  # error. It verifies, it is accepted, the request succeeds — no exception,
  # no metric, no log line, no failed request, nothing in any dashboard. An
  # operator who scales from one worker to two gets NO signal at all that
  # their origin stopped conforming (kiosk.tech protocol.md §15.2 and the
  # §16.1 operator profile). So the remedy is stated, not inferred:
  #   c.pow_spent_store = Kiosk::Server::PowSpentStores::ActiveRecord.new
  # plus the one table it needs — see the kiosk-server README, "Multi-process
  # deployments". kiosk-server also logs a warning at boot in production when
  # this default is in use with PoW on (K-752), but a warning nobody reads is
  # not the mitigation; this comment and the README are.
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
