# frozen_string_literal: true

# Kiosk-demo configuration — tudu, a MULTI-USER COLLABORATIVE todo app.
#
# The point of this demo: prove the four-verb wire carries collaboration no
# other demo shows — MEMBERSHIP-BASED many-to-many access (not owner-scoped),
# AGENT→AGENT invites expressed entirely at the app layer, and the W5 rebind
# hook (an agent works headless, the human links it, the hook migrates its
# lists). Like philslist there is NO `payment_provider`, so `capabilities`
# computes to schema/query/run and DROPS `pay` — the discovery documents
# advertise no payments (`demo:schema` asserts it).

# Env posture (ephemeral dev signing key, PoW secret, issuer, test flags) lives
# in config/environments/{development,test,production}.rb (K-650); this file
# reads the resolved values from Rails.configuration.x.kiosk.*.

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/pow_difficulty")
require Rails.root.join("lib/uuid_check")
require "kiosk/user_identity_providers/devise"

# Registration PoW gate — ALWAYS ON. With no payment gate, the registration PoW
# toll is the defense of a FREE app against spam signups — the same feature the
# commerce demos price fresh-identity minting with, new meaning. Register is now
# uniformly tolled on every demo (no per-demo env flag to remember): it activates
# on code-deploy and can't be forgotten. Params follow KIOSK_POW_DIFFICULTY
# (lib/pow_difficulty.rb): low (default) → n=96 k=5 sub-second; high → n=168 k=7
# (~10s / ~1.3 GiB). Unset = low, so the collab/link/isolation flows and CI stay
# fast; a deployer can set high to feel the toll. The prerequisites below MUST run
# unconditionally, else RegistrationPow.gate raises ConfigurationError at register.
TUDU_REGISTRATION_POW_PARAMS = PowDifficulty.params
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
  # The four queries and six actions are ordinary Rails controllers under
  # app/controllers/kiosk/ — `include Kiosk::Query` / `include Kiosk::Action`,
  # class-level macros, plain `render json:`. Nothing about them belongs in an
  # initializer, and nothing about them is here: this line only NAMES them, and
  # the engine loads and registers them (once in production, again after every
  # reload in development, so an edited/added/removed verb needs no restart).
  c.handlers = %w[Kiosk::HouseholdController Kiosk::TodoListsController]

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no role
  # separation in this demo). This demo runs WITHOUT RLS — isolation is
  # enforced at the app layer (the membership EXISTS-check that
  # `Membership.reachable?` runs for every list-scoped verb in the two handler
  # controllers named above) — so app_role and system_role are set to the same
  # role only to satisfy the config; no enable_rls_on / GRANT statements run here.
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
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. When
  # KIOSK_POW_DIFFICULTY=high, surface an honest "beware: intensive PoW" notice
  # here so an agent/reader sees the toll BEFORE it dials register (only shown
  # at high; tudu ships low so it is normally absent).
  c.owner  = { name: "tudu (Kiosk demo)", support: "demo@kiosk.tech" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Pin the universal skill (immutable versioned file on kiosk.tech), like the
  # sibling demos — the skill-pin guard validates this against the real file.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.11.md"
  c.skill_sha256 = "179b2320198c7a6a192f01df4555f604dca0cb90f0026827ded5b8eb277916b0"

  # ── NO payment_provider ──────────────────────────────────────────────────
  # This is deliberate and load-bearing: with no AP2 provider configured,
  # `pay` drops out of `capabilities` and the discovery documents carry no
  # payments block. tudu is a collaborative todo app — it takes no money.

  # JwtOrStubIdp tries Kiosk-issued JWTs (register/login output; the
  # account-binding token poll mints the same JWTs) first, then falls back to
  # StubIdp's bespoke `agent:u-…:a-…:r-…` shape. One endpoint authenticates
  # both for the demo.
  c.agent_idp = JwtOrStubIdp.new(stub: Rails.env.local? ? StubIdp.new : nil)
  # The provider's own web-session channel (Devise/Warden): authenticates the
  # approving human on the account-binding surfaces — the device verify page,
  # link-code mint, unlink, and the manage-assistants page. Walked by
  # `rake demo:link`.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  # Where the engine bounces an UNAUTHENTICATED browser visitor to the
  # manage-assistants page (this app's Devise sign-in). The engine stays
  # IdP-neutral, so the sign-in URL is supplied here; without it the page
  # would render a bare 401 (MANAGE-PAGE-UNAUTH-UX).
  c.sign_in_path = "/users/sign_in"

  # ── Headless assistant accounts ──────────────────────────────
  # When an agent registers with a FRESH key and no human behind it yet, the
  # framework calls this factory to mint the backing principal. tudu returns a
  # bare `users` row (no credentials) — a headless account. It can create lists
  # and add todos on its own; when the human later LINKS this key (the W5 link
  # ceremony), the rebind fires `assistant_claimed` below, migrating that
  # headless account's lists/memberships to the human.
  c.assistant_creation = ->(_pubkey) { User.create!.id }

  # ── The rebind hook — tudu's W5 completeness beat ───────────────────────
  # Fires inside AccountBinding.rebind's transaction (see kiosk-server
  # account_binding.rb) when a KNOWN key is re-parented to a human on link:
  #   config.assistant_claimed&.call(agent:, previous_user_id:, user_id:)
  # `agent` = kiosk.agents.id, `previous_user_id` = the headless account,
  # `user_id` = the human account. tudu migrates the headless account's domain
  # rows to the human. First real use of this hook in the repo (core never
  # touches provider rows). A raise here rolls the whole rebind back atomically.
  c.assistant_claimed = ->(agent:, previous_user_id:, user_id:) do
    conn = ActiveRecord::Base.connection
    # Lists owned by the headless account become the human's.
    conn.exec_update(<<~SQL, "assistant_claimed lists")
      UPDATE lists SET account_id = #{conn.quote(user_id)}
      WHERE account_id = #{conn.quote(previous_user_id)}
    SQL
    # Memberships too — but skip any list the human is ALREADY a member of
    # (the UNIQUE(list_id, account_id) index would otherwise collide); drop the
    # now-redundant headless membership instead.
    conn.exec_update(<<~SQL, "assistant_claimed memberships")
      UPDATE memberships SET account_id = #{conn.quote(user_id)}
      WHERE account_id = #{conn.quote(previous_user_id)}
        AND NOT EXISTS (
          SELECT 1 FROM memberships m2
          WHERE m2.list_id = memberships.list_id
            AND m2.account_id = #{conn.quote(user_id)}
        )
    SQL
    conn.exec_update(<<~SQL, "assistant_claimed drop dup memberships")
      DELETE FROM memberships
      WHERE account_id = #{conn.quote(previous_user_id)}
    SQL
    _ = agent # attribution available to the hook; not needed for the migration
  end

  # ── Registration PoW gate — ALWAYS ON (register is uniformly tolled) ──────
  c.registration_pow_count  = 1
  c.registration_pow_params = TUDU_REGISTRATION_POW_PARAMS
  c.pow_secret              = pow_secret
end

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  require Rails.root.join("lib/demo_telemetry")
  TUDU_VERB_MAP = {
    "create_list"    => "ran",
    "add_todo"       => "ran",
    "complete_todo"  => "ran",
    "invite"         => "ran",
    "accept_invite"  => "ran",
    "remove_member"  => "ran",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: TUDU_VERB_MAP,
  )
end
