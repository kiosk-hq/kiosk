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
require Rails.root.join("lib/pow_difficulty")
require "kiosk/user_identity_providers/devise"
require "securerandom"
require "base64"

# Registration PoW gate (KIOSK_POW_REGISTER_DEMO=1). With no payment gate, the
# optional registration PoW toll is the defense of a FREE app against spam
# signups — the same feature the commerce demos price fresh-identity minting
# with, new meaning. Params follow KIOSK_POW_DIFFICULTY (lib/pow_difficulty.rb):
# low (default) → n=96 k=5 sub-second; high → n=168 k=7 (~10s / ~1.3 GiB). Unset
# = low, so the collab/link/isolation flows and CI are unchanged; a deployer can
# set high to feel the toll. Off entirely unless KIOSK_POW_REGISTER_DEMO=1.
TUDU_REGISTRATION_POW_PARAMS = PowDifficulty.params
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
  # enforced at the app layer (the membership EXISTS-check in every query/Action)
  # — so app_role and system_role are set to the same role only to satisfy the
  # config; no enable_rls_on / GRANT statements run here.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3001")
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
  c.skill_url    = "https://kiosk.tech/skill-v0.3.5.md"
  c.skill_sha256 = "66d6a35ed96df828852781522e3c8cc2f73055ef2ec45ece96e42ff083e8712c"

  # ── NO payment_provider ──────────────────────────────────────────────────
  # This is deliberate and load-bearing: with no AP2 provider configured,
  # `pay` drops out of `capabilities` and the discovery documents carry no
  # payments block. tudu is a collaborative todo app — it takes no money.

  # JwtOrStubIdp tries Kiosk-issued JWTs (register/login output; the
  # account-binding token poll mints the same JWTs) first, then falls back to
  # StubIdp's bespoke `agent:u-…:a-…:r-…` shape. One endpoint authenticates
  # both for the demo.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # The provider's own web-session channel (Devise/Warden): authenticates the
  # approving human on the account-binding surfaces — the device verify page,
  # link-code mint, unlink, and the manage-assistants page. Walked by
  # `rake demo:link`.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new

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

  # ── Registration PoW gate (active only when KIOSK_POW_REGISTER_DEMO=1) ───
  if ENV["KIOSK_POW_REGISTER_DEMO"] == "1"
    c.registration_pow_count  = 1
    c.registration_pow_params = TUDU_REGISTRATION_POW_PARAMS
    c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET", "tudu-demo-pow-secret")
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# The authenticated principal (users.id). Identity is set via
# Kiosk::Server::SessionContext SET LOCAL, so current_user_id() resolves it.
# ActiveRecord has no direct access — pull it from PG.
def tudu_current_user_id
  ActiveRecord::Base.connection.select_value("SELECT kiosk.current_user_id()")
end

# The acting agent_id as a plain STRING (attribution for created_by_agent_id).
# Read the raw GUC — NOT kiosk.current_agent_id(), which casts to ::uuid and so
# would fail for the demo's stub tokens (agent_id like "alice-collab").
# Returns nil for the human web surface (no agent) and for uuid or stub agents.
def tudu_current_agent_id
  ActiveRecord::Base.connection.select_value(
    "SELECT NULLIF(current_setting('app.current_agent_id', true), '')",
  )
end

# Membership guard: raise 403 unless the GUC principal is a member of `list_id`.
# Forbidden (not NotFound) so cross-list probing can't enumerate which ids exist
# — the philslist pattern, adapted to membership-based access. `require_owner`
# tightens it to role='owner' (invite/remove_member authority).
def tudu_require_membership!(conn, list_id, require_owner: false)
  role_clause = require_owner ? "AND role = 'owner'" : ""
  ok = conn.select_value(<<~SQL)
    SELECT EXISTS (
      SELECT 1 FROM memberships
      WHERE list_id = #{conn.quote(list_id.to_s)}::uuid
        AND account_id = kiosk.current_user_id()
        #{role_clause}
    )
  SQL
  return if ok == true || ok == "t"

  raise Kiosk::Server::Errors::Forbidden.new(
    require_owner ? "list not owned by the authenticated principal" \
                  : "list not accessible by the authenticated principal",
    hint: require_owner ? "Only the list owner may do this." \
                        : "You may only reach lists you are a member of.",
  )
end

# ─── Queries (the `query` verb) — all membership-scoped ────────────────────────

# whoami — the GUC principal + acting agent. Handy first call for an agent
# orienting itself; also proves attribution wiring.
Kiosk::Server::Queries.register(
  "whoami",
  description: "Return the authenticated principal: { account_id, agent_id, handle } " \
               "resolved from the Kiosk GUC (kiosk.current_user_id / current_agent_id).",
  params: {},
) do |_params|
  conn       = ActiveRecord::Base.connection
  account_id = tudu_current_user_id
  agent_id   = tudu_current_agent_id
  handle     = conn.select_value(
    "SELECT email FROM users WHERE id = #{conn.quote(account_id.to_s)}::uuid",
  )
  [{ "account_id" => account_id, "agent_id" => agent_id, "handle" => handle }]
end

# my_lists — the lists the caller is a MEMBER of (owner OR member), via the
# memberships join. Membership-based, not owner-scoped: the caller sees lists it
# was invited into as well as its own. Provider-controlled WHERE; un-bypassable.
Kiosk::Server::Queries.register(
  "my_lists",
  description: "List the todo lists the authenticated principal is a member of " \
               "(owner or member), with the caller's role on each. Membership-based " \
               "access — includes lists the caller was invited into.",
  params: {},
) do |_params|
  ActiveRecord::Base.connection.execute(<<~SQL).to_a
    SELECT l.id AS list_id, l.title, m.role
      FROM lists l
      JOIN memberships m ON m.list_id = l.id
     WHERE m.account_id = kiosk.current_user_id()
     ORDER BY l.created_at DESC, l.id
  SQL
end

# list_todos(list_id) — membership-gated: 403 unless the caller is a member.
# Returns the list's todos with attribution (created_by_agent_id).
Kiosk::Server::Queries.register(
  "list_todos",
  description: "Return the todos on a list the caller is a member of, each with " \
               "its completion state and the agent that added it. Forbidden (403) " \
               "if the caller is not a member of the list.",
  params: {
    list_id: "uuid (required) — the list whose todos to read (see my_lists)",
  },
) do |params|
  conn = ActiveRecord::Base.connection
  tudu_require_membership!(conn, params[:list_id])
  conn.execute(<<~SQL).to_a
    SELECT id AS todo_id, title, done, created_by_agent_id
      FROM todos
     WHERE list_id = #{conn.quote(params[:list_id].to_s)}::uuid
     ORDER BY created_at, id
  SQL
end

# list_members(list_id) — membership-gated; returns the members + roles so a
# collaborator can see who else is on the list.
Kiosk::Server::Queries.register(
  "list_members",
  description: "Return the members of a list the caller is a member of: " \
               "{ account_id, handle, role }. Forbidden (403) if the caller is " \
               "not a member of the list.",
  params: {
    list_id: "uuid (required) — the list whose members to read (see my_lists)",
  },
) do |params|
  conn = ActiveRecord::Base.connection
  tudu_require_membership!(conn, params[:list_id])
  conn.execute(<<~SQL).to_a
    SELECT m.account_id, u.email AS handle, m.role
      FROM memberships m
      JOIN users u ON u.id = m.account_id
     WHERE m.list_id = #{conn.quote(params[:list_id].to_s)}::uuid
     ORDER BY m.role DESC, m.created_at
  SQL
end

# ─── Actions (the `run` verb) — every action opens with a membership check ─────

# create_list(title) — INSERT a list owned by the AUTHENTICATED principal and,
# in the SAME transaction, an `owner` membership for the caller. Any forged
# account_id/owner_id arg is IGNORED (owner is read from kiosk.current_user_id()).
Kiosk::Server::Actions.register(
  "create_list",
  description: "Create a new todo list owned by the authenticated principal. The " \
               "caller becomes its owner (an owner membership is created). Returns " \
               "{ list_id }.",
  params: {
    title: "string (required) — the list title",
  },
) do |args|
  conn       = ActiveRecord::Base.connection
  account_id = tudu_current_user_id
  raise Kiosk::Server::Errors::BadRequest.new("title required") if args[:title].to_s.strip.empty?

  list_id = conn.transaction do
    id = conn.select_value(<<~SQL)
      INSERT INTO lists (account_id, title, created_at, updated_at)
      VALUES (#{conn.quote(account_id)}::uuid, #{conn.quote(args[:title].to_s)}, now(), now())
      RETURNING id
    SQL
    conn.execute(<<~SQL)
      INSERT INTO memberships (list_id, account_id, role, created_at)
      VALUES (#{conn.quote(id)}::uuid, #{conn.quote(account_id)}::uuid, 'owner', now())
    SQL
    id
  end

  { list_id: list_id }
end

# add_todo(list_id, title) — membership-gated; records the acting agent as
# created_by_agent_id (attribution).
Kiosk::Server::Actions.register(
  "add_todo",
  description: "Add a todo to a list the caller is a member of. The acting agent " \
               "is recorded on the todo (attribution). Forbidden (403) if the caller " \
               "is not a member. Returns { todo_id }.",
  params: {
    list_id: "uuid (required) — the list to add to (see my_lists)",
    title:   "string (required) — the todo text",
  },
) do |args|
  conn = ActiveRecord::Base.connection
  tudu_require_membership!(conn, args[:list_id])
  raise Kiosk::Server::Errors::BadRequest.new("title required") if args[:title].to_s.strip.empty?

  agent_id = tudu_current_agent_id
  agent_sql = agent_id.nil? ? "NULL" : conn.quote(agent_id)
  todo_id = conn.select_value(<<~SQL)
    INSERT INTO todos (list_id, title, done, created_by_agent_id, created_at, updated_at)
    VALUES (#{conn.quote(args[:list_id].to_s)}::uuid, #{conn.quote(args[:title].to_s)},
            false, #{agent_sql}, now(), now())
    RETURNING id
  SQL

  { todo_id: todo_id }
end

# complete_todo(todo_id) — membership-gated via the todo's list. UPDATE …
# WHERE EXISTS(membership); zero rows → 403 (probing can't enumerate ids).
Kiosk::Server::Actions.register(
  "complete_todo",
  description: "Mark a todo done. Allowed only if the caller is a member of the " \
               "todo's list; otherwise forbidden (403). Returns { todo_id, done }.",
  params: {
    todo_id: "uuid (required) — the todo to complete (see list_todos)",
  },
) do |args|
  conn = ActiveRecord::Base.connection
  rows = conn.execute(<<~SQL)
    UPDATE todos SET done = true, updated_at = now()
    WHERE id = #{conn.quote(args[:todo_id].to_s)}::uuid
      AND EXISTS (
        SELECT 1 FROM memberships
        WHERE memberships.list_id = todos.list_id
          AND memberships.account_id = kiosk.current_user_id()
      )
    RETURNING id
  SQL

  if rows.ntuples.zero?
    raise Kiosk::Server::Errors::Forbidden.new(
      "todo not on a list the authenticated principal is a member of",
      hint: "You may only complete todos on lists you are a member of.",
    )
  end

  { todo_id: args[:todo_id], done: true }
end

# invite(list_id) — OWNER-ONLY. Mint a single-use, TTL'd (10 min) collaboration
# code; store ONLY its SHA-256 digest; return the plaintext { code, expires_in }
# ONCE. The code travels human-to-human; the recipient's agent redeems it via
# accept_invite.
Kiosk::Server::Actions.register(
  "invite",
  description: "Owner-only: mint a single-use, 10-minute collaboration code for a " \
               "list you own. The plaintext code is returned ONCE (only its hash is " \
               "stored) and is meant to be handed to another person, whose assistant " \
               "redeems it with accept_invite. Forbidden (403) if you are not the " \
               "list owner. Returns { code, expires_in }.",
  params: {
    list_id: "uuid (required) — the list to share (you must be its owner)",
  },
) do |args|
  conn = ActiveRecord::Base.connection
  tudu_require_membership!(conn, args[:list_id], require_owner: true)

  # A device_code-grade secret: 256 bits of entropy, base64url. Only the digest
  # is persisted (the kiosk-server LinkCode hygiene, adapted to the domain).
  code    = Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
  digest  = Invite.digest(code)
  ttl     = 600 # seconds (10 minutes)
  account = tudu_current_user_id
  conn.execute(<<~SQL)
    INSERT INTO invites (list_id, code_digest, created_by_account_id, expires_at, created_at)
    VALUES (#{conn.quote(args[:list_id].to_s)}::uuid, #{conn.quote(digest)},
            #{conn.quote(account)}::uuid, now() + interval '#{ttl} seconds', now())
  SQL

  { code: code, expires_in: ttl }
end

# accept_invite(code) — look up by digest; reject foreign/expired/redeemed (403);
# INSERT a `member` membership for the GUC principal; mark redeemed. A used code
# fails on the second try (single-use). Returns { list_id, joined: true }.
Kiosk::Server::Actions.register(
  "accept_invite",
  description: "Redeem a collaboration code someone shared with you: join their " \
               "list as a member. The code is single-use and expires; a used, " \
               "expired, or unknown code is forbidden (403). Returns { list_id, joined }.",
  params: {
    code: "string (required) — the plaintext invite code you were given",
  },
) do |args|
  conn   = ActiveRecord::Base.connection
  digest = Invite.digest(args[:code].to_s)

  forbidden = lambda do
    raise Kiosk::Server::Errors::Forbidden.new(
      "invite code is invalid, expired, or already used",
      hint: "Ask the list owner for a fresh code.",
    )
  end
  forbidden.call if args[:code].to_s.empty?

  result = conn.transaction do
    row = conn.execute(<<~SQL).first
      SELECT id, list_id, expires_at, redeemed_at
        FROM invites
       WHERE code_digest = #{conn.quote(digest)}
       FOR UPDATE
    SQL
    forbidden.call if row.nil?
    forbidden.call unless row["redeemed_at"].nil?
    expired = conn.select_value(
      "SELECT #{conn.quote(row['expires_at'])}::timestamptz < now()",
    )
    forbidden.call if expired == true || expired == "t"

    account = tudu_current_user_id
    list_id = row["list_id"]
    # Idempotent membership: UNIQUE(list_id, account_id) — if the caller is
    # already a member (e.g. the owner redeeming their own code), do nothing.
    conn.execute(<<~SQL)
      INSERT INTO memberships (list_id, account_id, role, created_at)
      VALUES (#{conn.quote(list_id)}::uuid, #{conn.quote(account)}::uuid, 'member', now())
      ON CONFLICT (list_id, account_id) DO NOTHING
    SQL
    conn.execute(<<~SQL)
      UPDATE invites
         SET redeemed_at = now(), redeemed_by_account_id = #{conn.quote(account)}::uuid
       WHERE id = #{conn.quote(row['id'])}::uuid
    SQL
    list_id
  end

  { list_id: result, joined: true }
end

# remove_member(list_id, account_id) — OWNER-ONLY. DELETE the target's
# membership; access is cut instantly. The owner cannot remove the LAST owner
# (no orphaning the list). Returns { removed: true }.
Kiosk::Server::Actions.register(
  "remove_member",
  description: "Owner-only: remove a member from a list you own — their access is " \
               "cut instantly. You cannot remove the list's last owner. Forbidden " \
               "(403) if you are not the owner. Returns { removed }.",
  params: {
    list_id:    "uuid (required) — the list to remove a member from (you must own it)",
    account_id: "uuid (required) — the member account to remove",
  },
) do |args|
  conn = ActiveRecord::Base.connection
  tudu_require_membership!(conn, args[:list_id], require_owner: true)

  target  = args[:account_id].to_s
  list_id = args[:list_id].to_s
  # Guard: never remove the list's LAST owner (would orphan the list). Refuse
  # when the target is an owner AND is the only owner remaining.
  removing_last_owner = conn.select_value(<<~SQL)
    SELECT
      EXISTS (SELECT 1 FROM memberships
                WHERE list_id = #{conn.quote(list_id)}::uuid
                  AND account_id = #{conn.quote(target)}::uuid
                  AND role = 'owner')
      AND (SELECT count(*) FROM memberships
             WHERE list_id = #{conn.quote(list_id)}::uuid
               AND role = 'owner') <= 1
  SQL
  if removing_last_owner == true || removing_last_owner == "t"
    raise Kiosk::Server::Errors::Forbidden.new(
      "cannot remove the list's last owner",
      hint: "A list must keep at least one owner.",
    )
  end

  rows = conn.execute(<<~SQL)
    DELETE FROM memberships
    WHERE list_id = #{conn.quote(list_id)}::uuid
      AND account_id = #{conn.quote(target)}::uuid
    RETURNING id
  SQL

  if rows.ntuples.zero?
    raise Kiosk::Server::Errors::Forbidden.new(
      "no such membership on this list",
      hint: "The account is not a member of this list.",
    )
  end

  { removed: true }
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
