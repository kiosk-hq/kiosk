# frozen_string_literal: true

# Kiosk-demo (stylish — Combette-shape) configuration. Concrete values for
# the salon-booking reference shape: uuid users, the engine's own agent IdP, five queries
# and one action, all of them ordinary Rails controllers named below.

# Env posture (ephemeral dev signing key, PoW secret, issuer, test flags) lives
# in config/environments/{development,test,production}.rb; this file reads the
# resolved values from Rails.configuration.x.kiosk.*.

require "kiosk/user_identity_providers/devise"

# Registration PoW gate — ALWAYS ON. A booking SaaS prices fresh-identity
# minting: registering an agent costs one Equihash proof, a metered toll.
# There is no env flag to forget. Params follow KIOSK_POW_DIFFICULTY
# (Kiosk::Pow::Equihash::Difficulty): low (default) → n=96 k=5, sub-second;
# high → n=168 k=7, ~1.3 GiB and ~10s on the reference numpy solver. The
# prerequisites below MUST run unconditionally, else RegistrationPow.gate
# raises ConfigurationError at register.
require "kiosk/pow/equihash"
STYLISH_REGISTRATION_POW_PARAMS = Kiosk::Pow::Equihash::Difficulty.params
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

# ── PoW HMAC secret — the key the engine signs every challenge with ─────────
# Required in production, stable non-secret default in dev/test; posture in
# config/environments/*.
pow_secret = Rails.configuration.x.kiosk.pow_secret

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  # ── Where the wire verbs live ──────────────────────────────────────────────
  # Ordinary Rails controllers under app/controllers/kiosk/. This line only
  # NAMES them; the engine loads and registers them, re-running after every
  # development reload so an edited verb needs no restart.
  # restart).
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
  # Advertised in /.well-known/kiosk.json, minted as the `iss` of every Kiosk
  # JWT, and enforced as the `aud` of every assistant proof-of-possession.
  c.issuer = Rails.configuration.x.kiosk.issuer

  # Validate the `Kiosk-PoW` header's proofs against the normative PoW schema,
  # so a malformed proof gets a clear 400 instead of a silent re-issued 402
  # loop. Needs the json_schemer gem.
  c.validate_requests = true

  # Validate every answer against the `output_schema` its verb declares: a
  # mismatch is a loud 500 rather than a lie shipped to an assistant. It is a
  # DEVELOPMENT/CI assertion — nothing a caller sends can trigger it — and it is
  # what makes the demo task list a per-verb conformance proof.
  #
  # OFF IN PRODUCTION deliberately: with it on, a descriptor typo becomes a 500
  # for a caller who did nothing wrong, and this demo is deployed. Nothing is
  # lost — every demo task list runs in development.
  c.validate_responses = !Rails.env.production?
  # stylish is dual-audience: VISITORS book a service off the menu (customer),
  # salon STAFF view the forecasted revenue (owner). The owner role comes from
  # the provider's own IdP — see `User#kiosk_role` and the `salon_calendar`
  # query in Kiosk::FrontDeskController.
  #
  # With TWO roles, role TOTALITY has teeth: `User#kiosk_role` MUST answer a
  # declared role for EVERY human, never nil. A role for staff and nothing for
  # customers is not a supported configuration — the ceremony would leave an
  # `owner` assistant at `owner` while its principal became a customer
  # (kiosk.tech `protocol.md` §6.3).
  c.roles  = %i[customer owner]
  # Role pinned to every SELF-registered agent (agents cannot choose their
  # own). Staff assistants get their role indirectly, from the bound human's
  # IdP role at link time — never self-selected.
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. At
  # KIOSK_POW_DIFFICULTY=high it also carries a "beware: intensive PoW" notice,
  # so a reader sees the toll before dialling register.
  c.owner  = { name: "Stylish (Kiosk demo)", support: "demo@kiosk.tech" }
  if (notice = Kiosk::Pow::Equihash::Difficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: Kiosk::Pow::Equihash::Difficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.4.12.md"
  c.skill_sha256 = "7d5be9bf841f8e05fd67b62b60d140fab584de373f8e28944298c93139f9a9ca"

  # ── NO c.agent_idp — deliberate ──────────────────────────────────────────
  # An assistant authenticates with the kiosk-pop JWT this engine minted, and
  # the engine verifies its own tokens: `IdentityResolution.agent_idp` falls
  # back to `AgentIdentityProviders::DefaultAgentIdp` when nothing is set.
  # SET IT only to front an EXTERNAL agent-identity issuer, by subclassing
  # `Kiosk::AgentIdentityProviders::Base` — whose one hard constraint is that
  # the `agent_id` it returns must be a UUID.
  #
  # The provider's own web-session channel (Devise/Warden): the /users/sign_in
  # cookie that approves links on the verify page, mints link codes, unlinks,
  # and drives the manage-assistants page. ONE channel in every environment.
  #
  # ROLES COME FROM THE PROVIDER'S OWN IdP, and this is the seam worth reading:
  # the salon's role comes from the provider's own users table. The Devise
  # adapter asks the User model for `#kiosk_role`, which returns the staff
  # member's `staff_role` — so an OWNER who signs in at /users/sign_in mints
  # link codes as `owner`, kiosk-server captures that role onto the link row
  # (AuthController#link → LinkCode.mint(requested_role:)), and the assistant
  # that redeems it inherits it. Walked by `rake demo:roles`.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  # Where the engine bounces an unauthenticated browser visitor to the
  # manage-assistants page. The engine stays IdP-neutral, so the URL is supplied
  # here; without it the page renders a bare 401.
  c.sign_in_path = "/users/sign_in"

  # ── NO spending_cap seam, and the reason is the same as the NO
  #    payment_provider one ──────────────────────────────────────────────────
  # `config.spending_cap` is read at exactly one site — `Executor#verb_pay`'s
  # mandate chain — and the provider check runs FIRST, so a `pay` here is
  # `403 no payment_provider configured` before a cart exists. stylish
  # configures no payment_provider (this salon takes payment in the chair), so a
  # seam set here could never be consulted.
  # What stylish DOES demonstrate is the governance surface above the cap — the
  # manage-assistants page writes `agents.spending_cap_cents`, which
  # `demo:binding` asserts end to end — and that is deliberate: a human sets the
  # policy on the page whether or not this origin is the one that charges.
  # An origin that both charges and caps sets `c.spending_cap =
  # Kiosk::Server::ColumnSpendingCap.new` beside its `payment_provider`.

  # ── Registration PoW gate — ALWAYS ON ────────────────────────────────────
  c.registration_pow_count  = 1
  c.registration_pow_params = STYLISH_REGISTRATION_POW_PARAMS
  c.pow_secret              = pow_secret

  # ── One process today. Before this origin ever runs two, read this ───────
  # `pow_spent_store` is left at its IN-PROCESS default, which is correct only
  # because each demo origin runs a SINGLE process. Two Puma workers, two pods,
  # or a rolling deploy where old and new overlap, each keep their OWN spent-id
  # set: one proof is then accepted once PER PROCESS and the toll above is
  # silently discounted. A replayed proof is not an error — it verifies, it is
  # accepted, and nothing appears in any dashboard — so the operator gets no
  # signal that their origin stopped conforming. The remedy:
  #   c.pow_spent_store = Kiosk::Server::PowSpentStores::ActiveRecord.new
  # plus the one table it needs; see the kiosk-server README, "Multi-process
  # deployments".
end
