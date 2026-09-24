# frozen_string_literal: true

# Kiosk-demo configuration — tudu, a MULTI-USER COLLABORATIVE todo app.
#
# The point of this demo: prove the per-verb wire carries collaboration no
# other demo shows — MEMBERSHIP-BASED many-to-many access (not owner-scoped),
# AGENT→AGENT invites expressed entirely at the app layer, and the W5 rebind
# hook (an agent works headless, the human links it, the hook migrates its
# lists). Like philslist there is NO `payment_provider`, so `capabilities`
# computes to schema/queries/actions and DROPS `pay` — the discovery documents
# advertise no payments (`demo:schema` asserts it).

# Env posture (ephemeral dev signing key, PoW secret, issuer, test flags) lives
# in config/environments/{development,test,production}.rb; this file reads the
# resolved values from Rails.configuration.x.kiosk.*.

require "kiosk/user_identity_providers/devise"

# Registration PoW gate — ALWAYS ON. With no payment gate, the registration PoW
# toll is what defends a FREE app against spam signups — the same feature the
# commerce demos price fresh-identity minting with. There is no env flag to
# forget. Params follow KIOSK_POW_DIFFICULTY (Kiosk::Pow::Equihash::Difficulty):
# low (default) → n=96 k=5, sub-second; high → n=168 k=7, ~1.3 GiB and ~10s on
# the reference numpy solver. The prerequisites below MUST run unconditionally,
# else RegistrationPow.gate raises ConfigurationError at register.
require "kiosk/pow/equihash"
TUDU_REGISTRATION_POW_PARAMS = Kiosk::Pow::Equihash::Difficulty.params
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
  c.handlers = %w[Kiosk::HouseholdController Kiosk::TodoListsController]

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no role
  # separation in this demo). This demo runs WITHOUT RLS — isolation is
  # enforced at the app layer (the membership EXISTS-check that
  # `Membership.reachable?` runs for every list-scoped verb in the two handler
  # controllers named above) — so app_role and system_role are set to the same
  # role only to satisfy the config; no enable_rls_on / GRANT statements run here.
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
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. When
  # KIOSK_POW_DIFFICULTY=high, surface an honest "beware: intensive PoW" notice
  # here so an agent/reader sees the toll BEFORE it dials register (only shown
  # at high; tudu ships low so it is normally absent).
  c.owner  = { name: "tudu (Kiosk demo)", support: "demo@kiosk.tech" }
  if (notice = Kiosk::Pow::Equihash::Difficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: Kiosk::Pow::Equihash::Difficulty.level, pow_notice: notice)
  end
  # Pin the universal skill (immutable versioned file on kiosk.tech), like the
  # sibling demos — the skill-pin guard validates this against the real file.
  c.skill_url    = "https://kiosk.tech/skill-v0.4.16.md"
  c.skill_sha256 = "abc054f7418a3573892753f20203c62449e10e6600ae3ef8ca2d6857a1403d4b"

  # ── NO payment_provider ──────────────────────────────────────────────────
  # This is deliberate and load-bearing: with no AP2 provider configured,
  # `pay` drops out of `capabilities` and the discovery documents carry no
  # payments block. tudu is a collaborative todo app — it takes no money.

  # ── NO c.agent_idp — deliberate ──────────────────────────────────────────
  # An assistant authenticates with the kiosk-pop JWT this engine minted, and
  # the engine verifies its own tokens: `IdentityResolution.agent_idp` falls
  # back to `AgentIdentityProviders::DefaultAgentIdp` when nothing is set.
  # SET IT only to front an EXTERNAL agent-identity issuer, by subclassing
  # `Kiosk::AgentIdentityProviders::Base` — whose one hard constraint is that
  # the `agent_id` it returns must be a UUID.
  #
  # The provider's own web-session channel (Devise/Warden): authenticates the
  # approving human on the account-binding surfaces — the device verify page,
  # link-code mint, unlink, and the manage-assistants page. Walked by
  # `rake demo:link`.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  # Where the engine bounces an unauthenticated browser visitor to the
  # manage-assistants page. The engine stays IdP-neutral, so the URL is supplied
  # here; without it the page renders a bare 401.
  c.sign_in_path = "/users/sign_in"

  # ── Headless assistant accounts ──────────────────────────────────────────
  # When an agent registers with a FRESH key and no human behind it yet, the
  # framework calls this factory to mint the backing principal. tudu returns a
  # bare `users` row with no credentials. It can create lists and add todos on
  # its own; when the human later LINKS this key, `assistant_claimed` below
  # migrates that headless account's lists and memberships to the human.
  c.assistant_creation = ->(_pubkey) { User.create!.id }

  # ── The rebind hook ──────────────────────────────────────────────────────
  # Fires inside AccountBinding.rebind's transaction when a KNOWN key is
  # re-parented to a human on link:
  #   config.assistant_claimed&.call(agent:, previous_user_id:, user_id:)
  # `previous_user_id` is the headless account, `user_id` the human one. tudu
  # migrates the headless account's domain rows across; core never touches
  # provider rows.
  #
  # THE TRANSACTION IS NOT THIS HOOK'S: `AccountBinding.rebind` opened it and
  # calls this inside it. `update_all` and `delete_all` start no transaction of
  # their own and `ApplicationRecord` leases the same connection, so all three
  # JOIN the rebind — which means a raise here rolls the whole rebind back
  # atomically.
  c.assistant_claimed = ->(agent:, previous_user_id:, user_id:) do
    # BELT AND BRACES. kiosk-server does not call this hook when the holder did
    # not actually change, and that engine guard is the primary defence. This
    # line is here because of what happens if it ever regresses: every
    # statement below reads "move the HEADLESS account's rows to the human",
    # and with previous_user_id == user_id the last one becomes "delete the
    # human's own memberships" — the migration UPDATE matches nothing (she is
    # already a member of her own lists) and the DELETE that exists only to
    # drop the now-redundant headless rows takes hers instead. She keeps
    # owning every list and can reach none of them.
    #
    # A destructive hook that is safe only because its caller is careful is
    # not safe. This one costs a comparison.
    next if previous_user_id.to_s == user_id.to_s

    # Lists owned by the headless account become the human's.
    List.where(account_id: previous_user_id).update_all(account_id: user_id)

    # Memberships too — but skip any list the human is ALREADY a member of (the
    # UNIQUE(list_id, account_id) index would otherwise collide); drop the
    # now-redundant headless membership instead.
    #
    # The guard is a `NOT IN (SELECT list_id …)` anti-join, and it is safe here
    # and only here: BOTH `memberships.list_id` and `memberships.account_id`
    # are `NOT NULL`, so the subquery can never yield a NULL and turn `NOT IN`
    # into "no rows". It stays ONE statement for the reason
    # RemoveMemberOperation gives — at READ COMMITTED a two-statement
    # read-then-write would straddle two snapshots.
    already_a_member = Membership.where(account_id: user_id).select(:list_id)
    Membership.where(account_id: previous_user_id)
              .where.not(list_id: already_a_member)
              .update_all(account_id: user_id)
    Membership.where(account_id: previous_user_id).delete_all

    _ = agent # attribution available to the hook; not needed for the migration
  end

  # ── Registration PoW gate — ALWAYS ON ────────────────────────────────────
  c.registration_pow_count  = 1
  c.registration_pow_params = TUDU_REGISTRATION_POW_PARAMS
  c.pow_secret              = pow_secret

  # ── The event tail lives in the DATABASE, not in this process ────────────
  # Set rather than defaulted, and the reason is the protocol's rather than
  # this shop's scale. Some topics are WAITS — the assistant asked and is
  # holding on for the answer. Others are SUBSCRIPTIONS: a delivery event
  # arrives hours after the order, a property's answer minutes after the
  # money. NOTHING holds a socket that long; an assistant is turn-based and
  # has no process that outlives its session, so it reconnects later and asks
  # for everything after the id it last saw. A tail that was in memory is gone
  # by then, and the only honest answer is `truncated: true` — which tells the
  # assistant to re-read state through an ordinary verb. That is the rare
  # degraded case; with the in-process default it is the answer after every
  # restart. Same seam as `pow_spent_store` above, opposite call.
  c.event_store = Kiosk::Server::EventStores::ActiveRecord.new

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
