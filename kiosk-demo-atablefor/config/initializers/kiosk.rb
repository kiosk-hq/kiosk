# frozen_string_literal: true

# Kiosk-demo (atablefor-shape) configuration. Concrete values for the
# restaurant table-booking reference shape: uuid users, the engine's own agent IdP,
# NO payment provider (a reservation takes no money), two queries and two
# actions, all of them ordinary Rails controllers named below.
#
# atablefor is a restaurant AGGREGATOR across a few Lisbon neighbourhoods
# (a static roster — see db/seeds.rb). Seatings are ROLLING-CURRENT: the
# upcoming evening seatings are computed relative to NOW in Europe/Lisbon
# (app/models/seatings.rb), never stale, but the tables are FINITE and CAN sell out
# for a given seating.

# Env posture (ephemeral dev signing key, PoW secret, issuer, test flags) lives
# in config/environments/{development,test,production}.rb (K-650); this file
# reads the resolved values from Rails.configuration.x.kiosk.*.

require "kiosk/user_identity_providers/devise"

# ── PoW / Reputation (R2) — the :query toll, selected by ATABLEFOR_POW_MODE ──
#
# Gate: the Equihash PoW challenge is issued ONLY for the :query verb.
# The :run verb is left ungated, so the existing no-human booking flow
# (script/book_flow.rb / rake demo:book) pays no :query toll. It is not
# proof-of-work-free: register is a SEPARATE gate and is ALWAYS ON, so the flow
# solves one Equihash proof on every run. That gate's own section below owns its
# detail; it is not restated here.
#
# The guard is intentional, and it is about the :query toll ONLY:
#   - rake demo:book boots the server WITHOUT KIOSK_POW_DEMO=1 → no :query toll.
#   - rake demo:pow  boots the server WITH   KIOSK_POW_DEMO=1 → :query toll active.
#
# WHICH TOLL A SENTENCE IS ABOUT HAS TO BE NAMED (K-1042, the K-1041 class one
# demo over). These lines used to state outright that the flow and the task
# involve no proof-of-work at all — an unconditional claim about this origin's
# posture, made under a header that scopes only the QUERY toll — and both were
# false about register. The repair shape was already in this file: the `off`
# entry of the KIOSK_POW_MODE list below ends «Registration PoW (below) stays on
# regardless», and that clause is exactly what makes the sentence closing that
# list («demo:book / demo:isolation / demo:redteam / demo:schema and CI stay
# toll-free») true where these two were not. What the code does:
# `c.registration_pow_count` and `c.registration_pow_params` are assigned inside
# `Kiosk.configure` and AFTER the `case ATABLEFOR_POW_MODE` block has ended, so
# no mode — `off` included — can reach them. And the flow the old sentence named
# is itself the proof: `script/book_flow.rb` registers through
# `equihash_register`, whose whole job is the 402 → solve → retry handshake. The
# old phrasing is deliberately not retyped here, so a grep for it finds live
# claims only.
#
# AND THE HEADER ABOVE NAMED AN ALIAS RATHER THAN THE SELECTOR (K-1045 — K-497
# rot, the third false posture claim in this block and the only one about the
# toll the header actually scopes). It gave the legacy `demo`-mode env flag as
# the toll's activation condition, which was true back when three
# mutually-overriding `if ENV[…]` blocks WERE the mechanism, and has been false
# since K-497 replaced them with ATABLEFOR_POW_MODE: the mode resolves to
# `:reputation` in production with no variable set at all, four other switches
# reach the same toll, and deploy/env/atablefor.env.example ships
# `KIOSK_POW_MODE=reputation` while setting that flag nowhere — so the header was
# false in the very environment this repo publishes for its flagship demo. The
# header now names the SELECTOR, and the mapping from variables to modes stays
# written out exactly once, at the selector below: re-listing it up here would
# make it a second copy to keep true, which is the K-1035/K-1038 class this file
# has already been repaired for twice. getgrocery's equivalent header was
# measured and is accurate — that demo never got a mode selector — so this is
# deliberately not swept wider.
#
# Reservation-scalping is exactly the abuse a table-booking provider fears:
# scripts that mass-claim prime-time 2-tops to resell. PoW prices that at the
# door — a metered toll per query, tuned per provider, not a hardware wall.
#
# Equihash params are chosen by KIOSK_POW_DIFFICULTY (app/services/pow_difficulty.rb):
#   low  (default) → n=96 k=5  — small, non-toy instance the reference solver
#                    clears in well under a second; local flows + CI stay fast.
#   high           → n=168 k=7 — the shipped default: ~1.3 GiB per proof, and
#                    ~10s on the reference numpy solver as measured on one
#                    M-series laptop core (the GiB is a property of the params;
#                    the seconds are that machine class). A real memory+CPU toll
#                    for the hosted deploy so a scalper feels the anti-scalping
#                    cost first-hand. Unset = low.
# Both the :query toll (KIOSK_POW_DEMO) and the anti-scalping reputation gate
# (KIOSK_POW_REPUTATION_DEMO) inherit this level.
#
# atablefor is INTENTIONALLY the ONE demo pinned to high in the hosted deploy
# (deploy/env/atablefor.env.example ships KIOSK_POW_DIFFICULTY=high). It is the
# designated production-grade showcase: a poker/scalper feels the real
# anti-reservation-scalping toll first-hand — ~1.3 GiB per proof, and ~9–10 s of
# it on an M-series laptop core, the only hardware the seconds have been
# measured on (the GiB is the reference solver's table at (n=168, k=7), not a
# floor those params impose on every solver; the seconds are not either); see
# the "beware" banner on the demo root page. Every other demo is
# knob-adjustable but defaults light so
# CI and quick poking stay fast; unset here still resolves to low.
EQUIHASH_DEMO_PARAMS = PowDifficulty.params

# ── Registration PoW gate — ALWAYS ON — POW-VERB-GATING (K-487)
#
# register is a verb like any other: a table-booking SaaS prices fresh-identity
# minting (one Equihash proof) so a scalper renting throwaway agents pays at the
# door. This is INDEPENDENT of the :query/:reputation/:backoff verb tolls above.
# Register is now uniformly tolled on every demo (no per-demo env flag to
# remember): it activates on code-deploy and can't be forgotten. Params follow
# KIOSK_POW_DIFFICULTY (atablefor ships high in the hosted deploy, so register
# inherits n=168 k=7 automatically).
#
# The gate REQUIRES kiosk-pow-equihash + kiosk-reputation required and the
# Equihash backend registered; those must run UNCONDITIONALLY (else
# RegistrationPow.gate raises ConfigurationError at register). require +
# Backends.register are idempotent, so the verb-toll guards below re-run them harmlessly.
ATABLEFOR_REGISTRATION_POW_PARAMS = PowDifficulty.params
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

# ── PoW verb-toll MODE — exactly one, explicitly selected (K-497) ──────────
#
# atablefor advertises ONE anti-scalping PoW policy on the :query verb.
# Historically three independent env flags each configured a DIFFERENT policy
# inside the same Kiosk.configure block; when more than one was set the LAST
# assignment silently won (last-block-wins). The live deploy set all three and
# quietly ran Backoff — not the reputation showcase it advertises — and Backoff's
# empty-factors reset even killed the reputation DB lookup. Collapsed to ONE
# explicit selector so exactly one policy can ever run:
#
#   KIOSK_POW_MODE = reputation | demo | backoff | off
#
#   reputation — the FLAGSHIP anti-scalping showcase (K-517=b): the shipped
#                RateAndReputation policy with a REAL confirmed-bookings DB
#                factor. A fresh/low-reputation agent pays escalating PoW to
#                browse prime-time availability; the cost DROPS as it builds a
#                genuine booking record. Hosted default (see below).
#   demo       — flat AtableforDemoPowPolicy: always toll :query (the demo:pow flow).
#   backoff    — "solve once, next N calls free" (N = KIOSK_POW_BACKOFF_DEMO, else 10).
#   off        — no :query toll. Registration PoW (below) stays on regardless.
#
# The legacy per-policy flags (KIOSK_POW_DEMO / KIOSK_POW_REPUTATION_DEMO /
# KIOSK_POW_BACKOFF_DEMO) are still honoured as single-mode aliases so the
# existing rake flows keep working, but setting MORE THAN ONE now RAISES at boot
# instead of silently picking the last. When nothing is set the mode is
# REPUTATION in production (the decided flagship policy) and OFF in dev/test, so
# demo:book / demo:isolation / demo:redteam / demo:schema and CI stay toll-free.
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
      They each select a DIFFERENT :query PoW policy and are mutually exclusive —
      setting several used to silently run only the last (K-497). Select exactly
      one policy with KIOSK_POW_MODE=reputation|demo|backoff|off and remove the
      legacy KIOSK_POW_DEMO / KIOSK_POW_REPUTATION_DEMO / KIOSK_POW_BACKOFF_DEMO flags.
    MSG
  elsif legacy.length == 1
    legacy.first
  else
    Rails.env.local? ? :off : :reputation
  end
end

# Per-mode setup that must run BEFORE Kiosk.configure (the demo policy class and
# the bad-proof counter stores). require + Backends.register already ran
# unconditionally above for registration PoW; they are idempotent.
case ATABLEFOR_POW_MODE
when :demo
  # Demo policy: always challenge :query (availability lookup); let :run through
  # freely. A real provider replaces this with Policies::RateAndReputation or a
  # domain-specific subclass. The inline class keeps the demo self-contained.
  class AtableforDemoPowPolicy < Kiosk::Reputation::Policy
    def initialize(pow_params)
      @pow_params = pow_params
    end

    # @return [{alg:, params:}] when verb is :query; nil otherwise.
    def challenge_for(identity:, verb:, factors:)
      return nil unless verb == :query

      { alg: Kiosk::Pow::Equihash::NAME, params: @pow_params }
    end
  end

  # ⚠ TOY COUNTER — NOT a reputation signal (K-498). Its ONLY job is to let the
  # local `script/pow_flow.rb` driver print "the server counted MY bad proof";
  # nothing reads it for policy (`reputation_factors` below feeds a hardcoded
  # `bad_proof_count: 0`). Since K-498's re-decision it counts PER IDENTITY in
  # sqlite (app/services/bad_proof_counter.rb): one abusive assistant can no longer
  # inflate anyone else's count, and concurrent server processes no longer
  # fight over one flat file. Two toy aspects REMAIN, deliberately, labelled:
  #   · NO TTL — and never resetting is equally wrong: a count that only grows
  #     condemns an identity for something a year old.
  # A production bad-proof count keeps the per-identity keying and adds decay
  # plus durability across restarts (the same gap as the in-process revocation
  # watermark). It must be specified before it is built, not bolted on here.
  #
  # WHERE IT LIVES, AND WHO WIPES IT (K-785, K-711). This file is what an
  # adopter copies, so it may not hardcode a path under /tmp, and it may not
  # truncate a store AT BOOT — a redeploy would silently zero the accumulated
  # signal. `rake demo:pow` OWNS the location: it wipes the file for a clean
  # slate and exports KIOSK_BAD_PROOF_DB to BOTH the server it spawns and the
  # driver that reads the counts back, so the two processes cannot drift onto
  # different files and report zero at each other. The PATH ITSELF is resolved
  # in config/environments/* like every other env input (K-1008,
  # ENV-CONFIG-PLACEMENT); this file only reads it, and the default over there
  # is only for a bare `rails s`.
  ATABLEFOR_BAD_PROOF_DB = Rails.configuration.x.kiosk.bad_proof_db
when :reputation
  # Anti-scalping mechanic: a fresh/low-reputation agent pays ESCALATING PoW
  # (N×PoW) to browse prime-time availability, and that cost DROPS as it builds a
  # real booking history (see the configure block for the RateAndReputation
  # params + the REAL confirmed-bookings DB factor that makes this a demo OF
  # reputation): 0 bookings → 2 proofs · 1 booking → 1 proof · 2+ → free pass.
  # ⚠ TOY COUNTER — the reputation branch's copy of the demo counter above;
  # the two remaining caveats there apply verbatim (boot-truncated, no TTL —
  # K-498; per-identity in sqlite since K-498's re-decision). Note this
  # branch's policy really does declare `bad_proof_count_factor: 3` — but its
  # factors hardcode `bad_proof_count: 0`, so this store still feeds nothing.
  # Wiring it in now would at least penalize only the offender, but a real
  # signal also needs decay before it becomes policy.
  # Same location rule as the :demo branch above (K-785). Nothing asserts these
  # counts — no driver reads this branch's store — so nothing wipes it either;
  # the "NO TTL" caveat above is the whole of its behaviour.
  ATABLEFOR_REPUTATION_BAD_PROOF_DB = Rails.configuration.x.kiosk.reputation_bad_proof_db
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

  # ── Where the wire verbs live (T-053 mixin / T-057) ────────────────────────
  # The queries and actions are ordinary Rails controllers under
  # app/controllers/kiosk/ — `include Kiosk::Handler`, class-level macros (`kind`
  # says which verb reaches each one), plain `render json:`. Nothing about them belongs in an
  # initializer, and nothing about them is here: this line only NAMES them, and
  # the engine loads and registers them (once in production, again after every
  # reload in development, so an edited/added/removed verb needs no restart).
  c.handlers = %w[Kiosk::DiningRoomController Kiosk::BookingsController]

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in this demo). This demo runs WITHOUT RLS enforcement —
  # isolation is enforced at the app layer (book_table's explicit user_id
  # scoping and the WHERE clauses in the two handler controllers named above) —
  # so app_role and system_role are set to the same role only to satisfy the
  # config; no enable_rls_on / GRANT statements run here.
  # ── Postgres role names (K-699/K-650) ────────────────────────────────────
  # Resolved in config/environments/*, like every other env input; read here.
  c.app_role    = Rails.configuration.x.kiosk.app_role
  c.system_role = Rails.configuration.x.kiosk.system_role

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
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. When
  # KIOSK_POW_DIFFICULTY=high, surface an honest "beware: intensive PoW" notice
  # here so an agent/reader sees the anti-scalping toll up front (the 402
  # challenge params carry the same heavy n/k).
  c.owner  = { name: "atablefor", support: "demo@kiosk.tech" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.4.9.md"
  c.skill_sha256 = "9b2e86ab5c2a655405505dd602a019a71c8c26752481749fab4f0b6ff307b02d"

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
  # The provider's own web-session channel (Devise/Warden): authenticates the
  # signed-in human diner on the account-binding surfaces — the link-code mint,
  # the device verify page, and unlink. A diner mints a link code here and their
  # assistant redeems it, binding the assistant to the diner's account. Walked
  # by `rake demo:binding`.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  # Where the engine bounces an UNAUTHENTICATED browser visitor to the
  # manage-assistants page (this app's Devise sign-in). The engine stays
  # IdP-neutral, so the sign-in URL is supplied here; without it the page
  # would render a bare 401 (MANAGE-PAGE-UNAUTH-UX).
  c.sign_in_path = "/users/sign_in"

  # ── NO payment_provider ──────────────────────────────────────────────────
  # This is deliberate and load-bearing: with no AP2 provider configured,
  # `pay` drops out of `capabilities` and the discovery documents carry no
  # payments block. atablefor books restaurant tables — a reservation takes
  # no money. The advertised capabilities are [schema, queries, actions].

  # ── PoW verb-toll gate — exactly one mode (K-497) ───────────────────────
  # ATABLEFOR_POW_MODE (resolved at the top of this file) selects exactly one
  # :query PoW policy, so the branches can no longer clobber each other's
  # reputation_policy / reputation_factors (the last-block-wins bug). In
  # particular the reputation branch's REAL confirmed-bookings DB factor can no
  # longer be reset to Factors.empty by a co-active backoff/demo branch — the
  # reset that had been killing the reputation lookup on the live flagship.
  # pow_secret is the required HMAC key resolved above (K-541).
  case ATABLEFOR_POW_MODE
  when :demo
    # Small, non-toy Equihash instance for demo speed (sub-second solve).
    pow_params = Kiosk::Pow::Equihash.params(**EQUIHASH_DEMO_PARAMS)

    c.reputation_policy = AtableforDemoPowPolicy.new(pow_params)
    c.pow_ttl           = 300

    # Factors: always return empty (the demo policy ignores factors and
    # challenges :query unconditionally). A real provider wires DB lookups.
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }

    # on_bad_proof: bump the TOY counter (see its definition above —
    # boot-truncated, TTL-less, K-498) so script/pow_flow.rb can assert the
    # rejection was counted. PER IDENTITY (K-498): keyed by the verified agent
    # credential id the gate hands in, so one abuser's rejections never appear
    # in anyone else's count.
    c.on_bad_proof = ->(identity:) {
      BadProofCounter.increment(ATABLEFOR_BAD_PROOF_DB, identity.agent_id)
    }
  when :reputation
    # The FLAGSHIP policy (K-517=b): the shipped RateAndReputation with REAL
    # confirmed-booking-count factors, escalating by PROOF COUNT (N×PoW):
    #   proven_purchases_threshold: 2  → 2 confirmed bookings → free pass
    #   base_count: 1, unproven_count_bonus: 1 → 0 bookings: 2 proofs;
    #                                            1 booking: 1 proof; 2+: nil
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

    # Factors: REAL DB lookup — COUNT(*) of the principal's CONFIRMED bookings.
    # This is what makes the flagship a demo OF reputation (K-517=b); it MUST NOT
    # be reset to Factors.empty (the last-block-wins reset K-497 eliminated) or
    # the policy can never grant relief. A confirmed reservation is this
    # provider's "proven completed action", mapped into settled_purchases_count.
    #
    # K-781: this was the last hand-quoted SQL in atablefor — a
    # `conn.execute("… WHERE user_id = #{conn.quote(uid)}::uuid …")` that seven
    # passes of handler migration walked past, because a CONFIG HOOK is not a
    # verb. It is a projection, so it reads through the model like every other
    # atablefor read, reusing {Booking.confirmed} rather than restating what
    # "confirmed" means beside the unique partial index that enforces it.
    #
    # `where(user_id:)` and NOT `Booking.owned_by_current_principal`, which is
    # sitting right there and is the wrong tool: the gate runs BEFORE the
    # Executor opens its SessionContext, so `kiosk.current_user_id()` is not set
    # yet. The principal arrives as the hook's `identity:` argument instead.
    #
    # Shape: the raw form cast to `::uuid`, so a malformed id raised
    # InvalidTextRepresentation (→ 500 inside the gate); `where(user_id:)` casts
    # an unparseable value to NULL and simply counts zero — i.e. the assistant
    # is asked for MORE proof, never less. `identity.user_id` is server-derived
    # from the verified token, so neither branch is caller-reachable.
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

    # Same TOY instrumentation as the :demo branch (K-498): per-identity,
    # boot-truncated, feeds no policy. Demo output only.
    c.on_bad_proof = ->(identity:) {
      BadProofCounter.increment(ATABLEFOR_REPUTATION_BAD_PROOF_DB, identity.agent_id)
    }
  when :backoff
    # "Solve once, next N calls free": one solved proof grants the assistant
    # `count` ungated follow-up calls, then it is re-challenged. The env value IS
    # the count (KIOSK_POW_BACKOFF_DEMO=10 grants 10; demo:backoff sets 3); when
    # mode is `backoff` with no count, default 10. base demands ONE fresh
    # Equihash proof. The in-process BackoffStore is authoritative per worker — a
    # multi-worker deploy needs a shared store (see BackoffStore's caveat).
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

    # The Backoff strategy ignores factors, but the gate still gathers them
    # (config.reputation_factors is called before challenge_for). Return empty.
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }
  end

  # ── Registration PoW gate — ALWAYS ON (register is uniformly tolled) ──────
  # Price fresh-identity minting: registering an agent costs ONE Equihash proof.
  # Independent of the verb toll above; pow_secret is set unconditionally so the
  # gate works even in :off mode (RegistrationPow.gate raises without it) — the
  # mode branches above share this one assignment.
  c.registration_pow_count  = 1
  c.registration_pow_params = ATABLEFOR_REGISTRATION_POW_PARAMS
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
  ATABLEFOR_VERB_MAP = {
    "book_table"     => "booked",
    "cancel_booking" => "cancelled",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: ATABLEFOR_VERB_MAP,
  )
end
