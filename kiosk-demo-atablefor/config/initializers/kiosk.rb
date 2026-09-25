# frozen_string_literal: true

# atablefor — a restaurant table-booking aggregator across a few Lisbon
# neighbourhoods (static roster, db/seeds.rb). Seatings are ROLLING-CURRENT:
# computed relative to NOW in Europe/Lisbon (app/models/seatings.rb); tables
# are FINITE and CAN sell out for a given seating.
#
# Env posture (signing key, PoW secret, issuer, test flags) lives in
# config/environments/*; this file reads Rails.configuration.x.kiosk.*.

require "kiosk/user_identity_providers/devise"

# ── PoW / Reputation — the verb toll, selected by ATABLEFOR_POW_MODE ────────
#
# The engine offers EVERY wire command to the gate, whatever its kind, and the
# SELECTED policy decides which verbs actually draw a challenge. Only the
# :demo policy below scopes the toll to :query; the :reputation policy — what
# a non-local boot gets — and :backoff never read the verb at all, so an
# action is tolled too: script/reputation_flow.rb books a table against a live
# challenge and is the thing to read. Registration PoW is a separate,
# always-on gate (own section below).
#
#   rake check:book — no PoW flag set  → :off in dev → nothing is tolled
#   rake check:pow  — KIOSK_POW_DEMO=1 → :demo → :query tolled, :run free
#
# Reservation-scalping is the abuse a table-booking provider fears: scripts
# that mass-claim prime-time 2-tops to resell. PoW prices that at the door —
# a metered toll per request, tuned per provider, not a hardware wall.
#
# KIOSK_POW_DIFFICULTY (Kiosk::Pow::Equihash::Difficulty) picks the params; both
# the verb toll and the registration gate inherit the level. Unset = low.
#   low  (default) → n=96 k=5  — sub-second on the reference solver; CI stays fast.
#   high           → n=168 k=7 — ~1.3 GiB and ~10s on the reference numpy solver
#                    on one M-series laptop core. The GiB is that solver's
#                    sorted-nonce table, not a floor the params impose: a
#                    memory-optimised solver trades it for time.
# The hosted atablefor deploy pins high (deploy/env/atablefor.env.example) so a
# scalper feels the real toll; see the "beware" banner on the demo root page.
require "kiosk/pow/equihash"
EQUIHASH_DEMO_PARAMS = Kiosk::Pow::Equihash::Difficulty.params

# ── Registration PoW gate — ALWAYS ON ───────────────────────────────────────
#
# register is a verb like any other: a table-booking SaaS prices fresh-identity
# minting (one Equihash proof) so a scalper renting throwaway agents pays at the
# door. Independent of the :query verb toll above; params follow
# KIOSK_POW_DIFFICULTY, and there is no env flag to forget.
#
# The require + Backends.register below must run UNCONDITIONALLY, outside any
# mode branch, or RegistrationPow.gate raises ConfigurationError at register.
# Both are idempotent.
ATABLEFOR_REGISTRATION_POW_PARAMS = Kiosk::Pow::Equihash::Difficulty.params
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

# ── PoW verb-toll MODE — exactly one, explicitly selected ──────────────────
#
#   KIOSK_POW_MODE = reputation | demo | backoff | off
#
#   reputation — the FLAGSHIP: the shipped RateAndReputation policy with a REAL
#                confirmed-bookings DB factor. A fresh agent pays escalating PoW
#                to browse prime-time availability; the cost DROPS as it builds
#                a genuine booking record.
#   demo       — flat AtableforDemoPowPolicy: always toll :query (rake check:pow).
#   backoff    — "solve once, next N calls free" (N = KIOSK_POW_BACKOFF_DEMO, else 10).
#   off        — no verb toll at all. Registration PoW (below) stays on regardless.
#
# ONE selector, because independent `if ENV[…]` blocks each assigning
# `reputation_policy` would leave only the LAST in effect, and a co-active
# branch's empty factors would reset the reputation DB lookup with it.
#
# The legacy per-policy flags (KIOSK_POW_DEMO / KIOSK_POW_REPUTATION_DEMO /
# KIOSK_POW_BACKOFF_DEMO) are honoured as single-mode aliases, but setting MORE
# THAN ONE RAISES at boot. Unset → REPUTATION in production, OFF in dev/test, so
# the demo flows and CI stay toll-free.
ATABLEFOR_POW_MODE = begin
  legacy = []
  legacy << :demo       if ENV["KIOSK_POW_DEMO"] == "1"
  legacy << :reputation if ENV["KIOSK_POW_REPUTATION_DEMO"] == "1"
  legacy << :backoff    if ENV["KIOSK_POW_BACKOFF_DEMO"].to_i > 0

  explicit = ENV["KIOSK_POW_MODE"].to_s.strip.downcase
  valid    = %w[off demo reputation backoff]

  if !explicit.empty?
    raise "KIOSK_POW_MODE=#{explicit.inspect} is invalid — use one of: #{valid.join(", ")}." unless valid.include?(explicit)
    stray = legacy.reject { |m| m.to_s == explicit }
    warn "[atablefor] KIOSK_POW_MODE=#{explicit} overrides legacy PoW flag(s): #{stray.join(", ")} — remove them." unless stray.empty?
    explicit.to_sym
  elsif legacy.length > 1
    raise <<~MSG
      More than one legacy PoW flag is set: #{legacy.join(", ")}.
      They each select a DIFFERENT :query PoW policy and are mutually exclusive.
      Select exactly
      one policy with KIOSK_POW_MODE=reputation|demo|backoff|off and remove the
      legacy KIOSK_POW_DEMO / KIOSK_POW_REPUTATION_DEMO / KIOSK_POW_BACKOFF_DEMO flags.
    MSG
  elsif legacy.length == 1
    legacy.first
  else
    Rails.env.local? ? :off : :reputation
  end
end

# Per-mode setup that must run BEFORE Kiosk.configure: the demo policy class and
# the bad-proof counter stores.
case ATABLEFOR_POW_MODE
when :demo
  # Demo policy: always challenge :query, let :run through. A real provider
  # replaces this with Policies::RateAndReputation or a domain subclass.
  class AtableforDemoPowPolicy < Kiosk::Reputation::Policy
    def initialize(pow_params)
      @pow_params = pow_params
    end

    def challenge_for(identity:, verb:, factors:)
      return nil unless verb == :query

      { alg: Kiosk::Pow::Equihash::NAME, params: @pow_params }
    end
  end

  # ⚠ TOY COUNTER — NOT a reputation signal. Nothing reads it for policy
  # (`reputation_factors` below hardcodes `bad_proof_count: 0`); it exists so
  # `script/pow_flow.rb` can print "the server counted MY bad proof". Keyed per
  # identity in sqlite (app/services/bad_proof_counter.rb), so one abuser cannot
  # inflate anyone else's count. It has NO TTL, and a count that only grows is
  # equally wrong: a production signal needs decay and durability first.
  #
  # `rake check:pow` owns the file's location — it wipes it and exports
  # KIOSK_BAD_PROOF_DB to both the server and the driver, so the two cannot
  # drift onto different files and report zero at each other.
  ATABLEFOR_BAD_PROOF_DB = Rails.configuration.x.kiosk.bad_proof_db
when :reputation
  # Anti-scalping: 0 bookings → 2 proofs · 1 booking → 1 proof · 2+ → free pass
  # (params in the configure block below).
  # ⚠ TOY COUNTER — same caveat as the :demo branch. This branch's policy does
  # declare `bad_proof_count_factor: 3`, but its factors hardcode
  # `bad_proof_count: 0`, so the store still feeds nothing and nothing wipes it.
  ATABLEFOR_REPUTATION_BAD_PROOF_DB = Rails.configuration.x.kiosk.reputation_bad_proof_db
end

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
  c.handlers = %w[Kiosk::DiningRoomController Kiosk::BookingsController]

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # ── Postgres role names ──────────────────────────────────────────────────
  # No RLS in this demo: isolation is enforced at the app layer (book_table's
  # explicit user_id scoping, and the WHERE clauses in the two handler
  # controllers above). app_role and system_role are the SAME role, set only to
  # satisfy the config — no enable_rls_on / GRANT runs here.
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
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. At
  # KIOSK_POW_DIFFICULTY=high it also carries a "beware: intensive PoW" notice,
  # so a reader sees the toll before the 402 does.
  c.owner  = { name: "atablefor", support: "demo@kiosk.tech" }
  if (notice = Kiosk::Pow::Equihash::Difficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: Kiosk::Pow::Equihash::Difficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.4.17.md"
  c.skill_sha256 = "feaffdab74e16a6aa665e9ea30d1cb53711e8f5be24768aa0d3f90f026e8db53"

  # ── NO c.agent_idp — deliberate ──────────────────────────────────────────
  # An assistant authenticates with the kiosk-pop JWT this engine minted, and
  # the engine verifies its own tokens: `IdentityResolution.agent_idp` falls
  # back to `AgentIdentityProviders::DefaultAgentIdp` when nothing is set.
  # SET IT only to front an EXTERNAL agent-identity issuer, by subclassing
  # `Kiosk::AgentIdentityProviders::Base` — whose one hard constraint is that
  # the `agent_id` it returns must be a UUID.
  #
  # user_idp is the provider's own web session (Devise/Warden): it authenticates
  # the signed-in human diner on the account-binding surfaces — link-code mint,
  # device verify, unlink. Walked by `rake check:binding`.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  # Where the engine bounces an unauthenticated browser visitor to the
  # manage-assistants page. The engine stays IdP-neutral, so the URL is supplied
  # here; without it the page renders a bare 401.
  c.sign_in_path = "/users/sign_in"

  # ── NO payment_provider ──────────────────────────────────────────────────
  # Deliberate and load-bearing: with no AP2 provider configured, `pay` drops
  # out of `capabilities` and the discovery documents carry no payments block.
  # A reservation takes no money, so capabilities are [schema, queries, actions].

  # ── PoW verb-toll gate — exactly one mode ───────────────────────────────
  # ATABLEFOR_POW_MODE (top of this file) selects exactly one :query policy, so
  # the branches cannot clobber each other's reputation_policy / factors.
  case ATABLEFOR_POW_MODE
  when :demo
    # Small, non-toy Equihash instance for demo speed (sub-second solve).
    pow_params = Kiosk::Pow::Equihash.params(**EQUIHASH_DEMO_PARAMS)

    c.reputation_policy = AtableforDemoPowPolicy.new(pow_params)
    c.pow_ttl           = 300

    # The demo policy ignores factors and challenges :query unconditionally.
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }

    # Bump the TOY counter (defined above) so script/pow_flow.rb can assert the
    # rejection was counted. Keyed by the verified agent credential id.
    c.on_bad_proof = ->(identity:) {
      BadProofCounter.increment(ATABLEFOR_BAD_PROOF_DB, identity.agent_id)
    }
  when :reputation
    # The shipped RateAndReputation, escalating by PROOF COUNT (N×PoW):
    #   0 bookings: 2 proofs · 1 booking: 1 proof · 2+ (the threshold): free.
    c.reputation_policy = Kiosk::Reputation::Policies::RateAndReputation.new(
      proven_purchases_threshold: 2,
      low_rate_threshold:         100,
      base_count:                 1,
      count_min:                  1,
      count_max:                  10,
      rate_count_step:            1,
      rate_step:                  10,
      unproven_count_bonus:       1,
      bad_proof_count_factor:     3,
      equihash_n:                 EQUIHASH_DEMO_PARAMS[:n],
      equihash_k:                 EQUIHASH_DEMO_PARAMS[:k],
    )
    c.pow_ttl = 300

    # Factors: REAL DB lookup — COUNT(*) of the principal's CONFIRMED bookings,
    # this provider's "proven completed action". It MUST NOT be reset to
    # Factors.empty or the policy can never grant relief.
    #
    # `where(user_id:)` and NOT `Booking.owned_by_current_principal`, which is
    # sitting right there and is the wrong tool: the gate runs BEFORE the
    # Executor opens its SessionContext, so `kiosk.current_user_id()` is not set
    # yet. The principal arrives as the hook's `identity:` argument instead.
    c.reputation_factors = ->(identity:, **) {
      count = Booking.confirmed.where(user_id: identity.user_id).count
      Kiosk::Reputation::Factors.new(
        kyc_level:               nil,
        settled_purchases_count: count,
        settled_purchases_cents: nil,
        request_rate_per_min:    0,
        account_age_seconds:     nil,
        dispute_count:           nil,
        bad_proof_count:         0,
      )
    }

    # Same TOY instrumentation as the :demo branch: feeds no policy.
    c.on_bad_proof = ->(identity:) {
      BadProofCounter.increment(ATABLEFOR_REPUTATION_BAD_PROOF_DB, identity.agent_id)
    }
  when :backoff
    # "Solve once, next N calls free": one proof grants `count` ungated
    # follow-up calls, then the assistant is re-challenged. The env value IS the
    # count (check:backoff sets 3); default 10. The in-process BackoffStore is
    # per worker — a multi-worker deploy needs a shared store.
    backoff_count = ENV["KIOSK_POW_BACKOFF_DEMO"].to_i
    backoff_count = 10 if backoff_count < 1
    c.reputation_policy = Kiosk::Reputation::Policies::Backoff.new(
      count: backoff_count,
      base:  {
        alg:    Kiosk::Pow::Equihash::NAME,
        params: Kiosk::Pow::Equihash.params(**EQUIHASH_DEMO_PARAMS),
        count:  1,
      },
    )
    c.pow_ttl = 300

    # Backoff ignores factors, but the gate still gathers them before
    # challenge_for, so this must be set.
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }
  end

  # ── Registration PoW gate — ALWAYS ON ────────────────────────────────────
  # Registering an agent costs ONE Equihash proof. pow_secret is assigned
  # unconditionally, outside the mode branches, so the gate still works in
  # :off mode — RegistrationPow.gate raises without it.
  c.registration_pow_count  = 1
  c.registration_pow_params = ATABLEFOR_REGISTRATION_POW_PARAMS
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
