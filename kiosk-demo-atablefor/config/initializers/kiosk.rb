# frozen_string_literal: true

# Kiosk-demo (atablefor-shape) configuration. Concrete values for the
# restaurant table-booking reference shape: uuid users, JWT-or-stub IdP,
# NO payment provider (a reservation takes no money), Actions
# (book_table, cancel_booking).
#
# atablefor is a restaurant AGGREGATOR across a few Lisbon neighbourhoods
# (a static roster — see db/seeds.rb). Seatings are ROLLING-CURRENT: the
# upcoming evening seatings are computed relative to NOW in Europe/Lisbon
# (lib/seatings.rb), never stale, but the tables are FINITE and CAN sell out
# for a given seating.

# ── Ephemeral dev signing key ─────────────────────────────────────────────
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
require Rails.root.join("lib/pow_difficulty")
require Rails.root.join("lib/seatings")
require "kiosk/user_identity_providers/devise"

# ── PoW / Reputation (R2) — activated only when KIOSK_POW_DEMO=1 ──────────
#
# Gate: the Equihash PoW challenge is issued ONLY for the :query verb.
# The :run verb is left ungated so the existing no-human booking flow
# (book_flow.rb / rake demo:book) continues to pass without any PoW handling.
#
# The guard is intentional:
#   - rake demo:book boots the server WITHOUT KIOSK_POW_DEMO=1 → no PoW.
#   - rake demo:pow  boots the server WITH   KIOSK_POW_DEMO=1 → PoW active.
#
# Reservation-scalping is exactly the abuse a table-booking provider fears:
# scripts that mass-claim prime-time 2-tops to resell. PoW prices that at the
# door — a metered toll per query, tuned per provider, not a hardware wall.
#
# Equihash params are chosen by KIOSK_POW_DIFFICULTY (lib/pow_difficulty.rb):
#   low  (default) → n=96 k=5  — small, non-toy instance the reference solver
#                    clears in well under a second; local flows + CI stay fast.
#   high           → n=168 k=7 — the shipped default (~10s / ~1.3 GiB): a real
#                    memory+CPU toll for the hosted deploy so a scalper feels
#                    the anti-scalping cost first-hand. Unset = low.
# Both the :query toll (KIOSK_POW_DEMO) and the anti-scalping reputation gate
# (KIOSK_POW_REPUTATION_DEMO) inherit this level.
#
# atablefor is INTENTIONALLY the ONE demo pinned to high in the hosted deploy
# (deploy/env/atablefor.env.example ships KIOSK_POW_DIFFICULTY=high). It is the
# designated production-grade showcase: a poker/scalper feels the real ~9–10 s /
# ~1.3 GiB anti-reservation-scalping toll first-hand (see the "beware" banner on
# the demo root page). Every other demo is knob-adjustable but defaults light so
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
# the bad-proof counter files). require + Backends.register already ran
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

  # Counter file written by on_bad_proof; the pow_flow.rb driver reads it.
  ATABLEFOR_BAD_PROOF_FILE = "/tmp/kiosk-atablefor-bad-proof.count"
  File.write(ATABLEFOR_BAD_PROOF_FILE, "0")
when :reputation
  # Anti-scalping mechanic: a fresh/low-reputation agent pays ESCALATING PoW
  # (N×PoW) to browse prime-time availability, and that cost DROPS as it builds a
  # real booking history (see the configure block for the RateAndReputation
  # params + the REAL confirmed-bookings DB factor that makes this a demo OF
  # reputation): 0 bookings → 2 proofs · 1 booking → 1 proof · 2+ → free pass.
  ATABLEFOR_REPUTATION_BAD_PROOF_FILE = "/tmp/kiosk-atablefor-reputation-bad-proof.count"
  File.write(ATABLEFOR_REPUTATION_BAD_PROOF_FILE, "0")
end

# Inject the RLS DSL into ActiveRecord::Migration so migrations can call
# `enable_rls_on TABLE do ... end` directly. atablefor keeps kiosk-rls wired as
# the baseline data plane (all 7 demos do); it simply ships no RLS *showcase*
# task — booking has no apt RLS beat. The kiosk-rls README documents this opt-in.
ActiveRecord::Migration.include(Kiosk::RLS::DSL)

# ── PoW HMAC secret — REQUIRED outside development/test (K-541) ────────────
# pow_secret is the HMAC key the engine signs every PoW challenge with. This
# repo is PUBLIC, so a shipped fallback would be world-readable: a reader could
# mint a self-signed challenge at trivial difficulty {n:8,k:1} and forge a proof
# the server accepts — silently turning proof-of-work OFF. It MUST come from the
# environment in production and fail LOUD when absent, matching KIOSK_ISSUER and
# the signing key. Dev/test keep a stable (non-secret) default so `bin/rails s`,
# the demo drivers and e2e boot out of the box; a too-short secret is rejected.
pow_secret = ENV.fetch("KIOSK_POW_SECRET") do
  unless Rails.env.local?
    raise <<~MSG
      KIOSK_POW_SECRET is required outside development/test.

      It is the HMAC key every Kiosk PoW challenge is signed with. This repo is
      public, so a shipped fallback would be world-readable — anyone could mint a
      self-signed challenge at trivial difficulty and forge a valid proof,
      silently turning proof-of-work off. Generate a long random value:

        KIOSK_POW_SECRET=$(openssl rand -hex 32)
    MSG
  end
  "atablefor-demo-pow-secret-dev-insecure-default"
end
raise "KIOSK_POW_SECRET must be at least 32 bytes (got #{pow_secret.bytesize}) — generate one with `openssl rand -hex 32`." if pow_secret.bytesize < 32

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in this demo). This demo runs WITHOUT RLS enforcement —
  # isolation is enforced at the app layer (the book_table Action's explicit
  # user_id scoping and the my_bookings query's own WHERE predicate) — so
  # app_role and system_role are set to the same role only to satisfy the
  # config; no enable_rls_on / GRANT statements run here.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  # ── Issuer origin — REQUIRED outside development/test (K-510) ────────────
  # `issuer` is this operator's canonical origin, and it is load-bearing three
  # times over: it is advertised in /.well-known/kiosk.json, it is the `iss` of
  # every JWT this app mints, and PopVerifier enforces it as the `aud` of every
  # assistant proof. A deployment that silently fell back to localhost would
  # boot HAPPILY and then reject every assistant that dialed the real host with
  # "proof audience mismatch" — a total, silent auth outage from one unset
  # variable, whose error text points the agent at an origin it never visited.
  # So it fails LOUD at boot, matching the signing key (kiosk-server's
  # default_signing_key raises when KIOSK_SIGNING_KEY_PEM/_B64 is absent).
  # Development and test keep a localhost default so `bin/rails s` and the demo
  # flows run out of the box; the port follows the one the server actually
  # binds (PORT, the same variable lib/tasks/demo.rake and `rails s` read).
  c.issuer = ENV.fetch("KIOSK_ISSUER") do
    unless Rails.env.local?
      raise <<~MSG
        KIOSK_ISSUER is required outside development/test.

        It is this operator's canonical origin: advertised in
        /.well-known/kiosk.json, minted as the `iss` of every Kiosk JWT, and
        enforced as the `aud` of every assistant proof-of-possession. Falling
        back to localhost here would reject EVERY assistant with "proof
        audience mismatch".

        Set it to the origin agents actually dial:
          KIOSK_ISSUER=https://atablefor.demo.kiosk.tech
      MSG
    end

    "http://localhost:#{ENV.fetch("PORT", "3002")}"
  end

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
  # here so an agent/reader sees the anti-scalping toll up front (the 402
  # challenge params carry the same heavy n/k).
  c.owner  = { name: "atablefor", support: "help@atablefor.app" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.10.md"
  c.skill_sha256 = "67265bd147ea3c6c32b240b1f2fc17f57ba17342770b989270ce34eb3f302a91"

  # JwtOrStubIdp tries Kiosk-issued JWTs (kiosk-pop register/login output;
  # OAuth device-grant dormant) first, then falls back to StubIdp's bespoke
  # `agent:u-…:a-…:r-…` shape. One endpoint authenticates both for the demo.
  # Real providers swap in `kiosk-user-idp-devise` (or another adapter).
  c.agent_idp = JwtOrStubIdp.new(stub: Rails.env.local? ? StubIdp.new : nil)
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
  # no money. The advertised capabilities are [schema, query, run].

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
    c.pow_secret        = pow_secret
    c.pow_ttl           = 300

    # Factors: always return empty (the demo policy ignores factors and
    # challenges :query unconditionally). A real provider wires DB lookups.
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }

    # on_bad_proof: increment the counter file so pow_flow.rb can assert it.
    c.on_bad_proof = ->(identity:) {
      count = (File.read(ATABLEFOR_BAD_PROOF_FILE).to_i rescue 0)
      File.write(ATABLEFOR_BAD_PROOF_FILE, (count + 1).to_s)
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
    c.pow_secret = pow_secret
    c.pow_ttl    = 300

    # Factors: REAL DB lookup — COUNT(*) of the principal's CONFIRMED bookings.
    # This is what makes the flagship a demo OF reputation (K-517=b); it MUST NOT
    # be reset to Factors.empty (the last-block-wins reset K-497 eliminated) or
    # the policy can never grant relief. A confirmed reservation is this
    # provider's "proven completed action", mapped into settled_purchases_count.
    c.reputation_factors = ->(identity:, **) {
      uid  = identity.user_id
      conn = ActiveRecord::Base.connection
      count = conn.execute(
        "SELECT COUNT(*) AS confirmed_count FROM bookings " \
        "WHERE user_id = #{conn.quote(uid.to_s)}::uuid AND status = 'confirmed'"
      ).first["confirmed_count"].to_i
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

    c.on_bad_proof = ->(identity:) {
      cnt = (File.read(ATABLEFOR_REPUTATION_BAD_PROOF_FILE).to_i rescue 0)
      File.write(ATABLEFOR_REPUTATION_BAD_PROOF_FILE, (cnt + 1).to_s)
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
    c.pow_secret = pow_secret
    c.pow_ttl    = 300

    # The Backoff strategy ignores factors, but the gate still gathers them
    # (config.reputation_factors is called before challenge_for). Return empty.
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }
  end

  # ── Registration PoW gate — ALWAYS ON (register is uniformly tolled) ──────
  # Price fresh-identity minting: registering an agent costs ONE Equihash proof.
  # Independent of the verb toll above; pow_secret is set here too so the gate
  # works even in :off mode (RegistrationPow.gate raises without it).
  c.registration_pow_count  = 1
  c.registration_pow_params = ATABLEFOR_REGISTRATION_POW_PARAMS
  c.pow_secret              = pow_secret
end

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  require Rails.root.join("lib/demo_telemetry")
  ATABLEFOR_VERB_MAP = {
    "book_table"     => "booked",
    "cancel_booking" => "cancelled",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: ATABLEFOR_VERB_MAP,
  )
end

# ─── Queries ────────────────────────────────────────────────────────────────

# availability — open tables ACROSS the restaurant aggregator for the upcoming
# rolling seatings that seat the party. Public (no per-user scoping): any
# authenticated agent may browse. The upcoming seatings (tonight's 19/20/21 in
# Europe/Lisbon, past ones filtered, rolling to tomorrow) are computed by
# lib/seatings.rb — so availability is NEVER stale. Tables are FINITE: a table
# is "open" for a seating only when no CONFIRMED booking already holds it for
# that exact (table, seating_at); when every table for a seating is taken,
# availability is legitimately EMPTY for it (honest sell-out).
#
# Optional filters (all agent input goes through conn.quote — data, never SQL):
#   :party_size   — only tables seating at least this many (used to size the party)
#   :neighborhood — restrict to one Lisbon neighbourhood (e.g. "Alfama")
#   :time         — restrict to one seating time ("19:00" | "20:00" | "21:00")
#   :date         — restrict to one date (YYYY-MM-DD) among the upcoming seatings
# The result is small (~5 restaurants × a handful of tables × ≤ a few seatings),
# so it is NOT paginated.
Kiosk::Server::Queries.register("availability",
                                 description: "List open restaurant tables across the aggregator for the " \
                                              "UPCOMING seatings that seat the party (params: party_size; " \
                                              "optional neighborhood, time, date filters). Returns one row " \
                                              "per open (restaurant, table, seating): restaurant, " \
                                              "neighborhood, cuisine, restaurant_id, restaurant_table_id, " \
                                              "table_label, capacity, seating_date, seating_time, seating_at, " \
                                              "deposit_eur. Pass restaurant_id + restaurant_table_id + date + " \
                                              "time + party_size to book_table (all five are required) — the " \
                                              "row field named seating_date is book_table's `date` param, and " \
                                              "the row's seating_time is book_table's `time`: same values, " \
                                              "different names. Seatings are the current " \
                                              "upcoming ones (Europe/Lisbon), never stale; a seating with " \
                                              "every table taken is absent (sold out). deposit_eur is the " \
                                              "no-show hold in whole EUR (0 = none), settled at the " \
                                              "restaurant — no online payment. Small; not paginated.",
                                 params: {
                                   party_size:   "integer — number of guests; only tables seating at least this many are returned",
                                   neighborhood: "string (optional) — restrict to one Lisbon neighbourhood, e.g. \"Alfama\"",
                                   time:         "string (optional) — restrict to one seating time (\"19:00\" | \"20:00\" | \"21:00\")",
                                   date:         "string (optional) — restrict to one date (YYYY-MM-DD) among the upcoming seatings",
                                 },
                                 input_schema: {
                                   type: "object",
                                   additionalProperties: false,
                                   properties: {
                                     party_size:   { type: "integer", minimum: 1,
                                                     description: "Number of guests." },
                                     neighborhood: { type: "string",
                                                     description: "Optional Lisbon neighbourhood filter, e.g. \"Alfama\"." },
                                     time:         { type: "string", pattern: "^[0-2][0-9]:[0-5][0-9]$",
                                                     description: "Optional seating-time filter, \"19:00\" | \"20:00\" | \"21:00\"." },
                                     date:         { type: "string", format: "date",
                                                     description: "Optional date filter, YYYY-MM-DD (must be among the upcoming seatings)." },
                                   },
                                   required: ["party_size"],
                                 },
                                 example_params: { party_size: 2, neighborhood: "Alfama" },
                                 example_row: {
                                   restaurant: "Tasca do Tejo", neighborhood: "Alfama",
                                   cuisine: "Portuguese tavern", restaurant_id: 1,
                                   restaurant_table_id: 1, table_label: "Window 6", capacity: 2,
                                   seating_date: "2026-08-08", seating_time: "20:00",
                                   seating_at: "2026-08-08T20:00:00+01:00", deposit_eur: 10,
                                 }) do |params|
  party_size = (params.fetch(:party_size) { raise Kiosk::Server::Errors::BadRequest.new("missing param: party_size") }).to_i
  raise Kiosk::Server::Errors::BadRequest.new("party_size must be >= 1") if party_size < 1

  nbhd_filter = (params[:neighborhood] || params["neighborhood"]).to_s
  time_filter = (params[:time]         || params["time"]).to_s
  date_filter = (params[:date]         || params["date"]).to_s

  conn = ActiveRecord::Base.connection

  # The rolling upcoming seatings (Europe/Lisbon, past filtered, tonight→tomorrow),
  # each optionally narrowed by the agent's time/date filter.
  seatings = Seatings.upcoming
  seatings = seatings.select { |_d, t|   t == time_filter } unless time_filter.empty?
  seatings = seatings.select { |d, _t| d.iso8601 == date_filter } unless date_filter.empty?
  return [] if seatings.empty?

  # Every physical table seating >= party, optionally in one neighbourhood.
  where_nbhd = nbhd_filter.empty? ? "" : "AND r.neighborhood = #{conn.quote(nbhd_filter)} "
  tables = conn.execute(
    "SELECT rt.id AS restaurant_table_id, rt.label AS table_label, rt.capacity, rt.deposit_eur, " \
    "r.id AS restaurant_id, r.name AS restaurant, r.neighborhood, r.cuisine " \
    "FROM restaurant_tables rt " \
    "JOIN restaurants r ON r.id = rt.restaurant_id " \
    "WHERE rt.capacity >= #{party_size} #{where_nbhd}" \
    "ORDER BY r.name, rt.capacity, rt.label"
  ).to_a

  # Confirmed holds on any of the upcoming seatings — used to subtract taken
  # (table, seating) pairs so availability sells out honestly. Keyed on the
  # ABSOLUTE instant (UTC epoch seconds) so the match is timezone-agnostic — the
  # seating_at column is timestamptz, and Seatings.seating_at is a zoned Lisbon
  # Time; both reduce to the same epoch, sidestepping session-TZ formatting.
  seating_epochs = seatings.map { |d, t| Seatings.seating_at(d, t).to_i }
  taken = {}
  unless seating_epochs.empty?
    in_list = seatings.map { |d, t| "#{conn.quote(Seatings.seating_at(d, t).iso8601)}::timestamptz" }.join(", ")
    conn.execute(
      "SELECT restaurant_table_id, EXTRACT(EPOCH FROM seating_at)::bigint AS epoch " \
      "FROM bookings WHERE status = 'confirmed' AND seating_at IN (#{in_list})"
    ).each { |row| taken["#{row["restaurant_table_id"]}@#{row["epoch"]}"] = true }
  end

  rows = []
  seatings.each do |date, time|
    seating_at = Seatings.seating_at(date, time)
    key_epoch  = seating_at.to_i
    tables.each do |t|
      next if taken["#{t["restaurant_table_id"]}@#{key_epoch}"]

      rows << {
        "restaurant"          => t["restaurant"],
        "neighborhood"        => t["neighborhood"],
        "cuisine"             => t["cuisine"],
        "restaurant_id"       => t["restaurant_id"],
        "restaurant_table_id" => t["restaurant_table_id"],
        "table_label"         => t["table_label"],
        "capacity"            => t["capacity"],
        "seating_date"        => date.iso8601,
        "seating_time"        => time,
        "seating_at"          => seating_at.iso8601,
        "deposit_eur"         => t["deposit_eur"],
      }
    end
  end
  rows
end

# my_bookings — per-user booking list scoped by the session GUC.
# The WHERE is provider-controlled; the agent supplies no filter. This
# demonstrates app-layer per-user isolation: the principal can only see rows
# where user_id matches kiosk.current_user_id(), enforced in the query itself.
Kiosk::Server::Queries.register("my_bookings",
                                 description: "List this principal's table bookings across all restaurants " \
                                              "(scoped to the authenticated user via kiosk.current_user_id()). " \
                                              "Each row carries a `booking_id`; pass it to cancel_booking as " \
                                              "`booking_id`.") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT b.id AS booking_id, b.restaurant_id, r.name AS restaurant, r.neighborhood, " \
    "b.restaurant_table_id, rt.label AS table_label, b.party_size, b.status, " \
    "to_char(b.seating_at AT TIME ZONE 'Europe/Lisbon', 'YYYY-MM-DD') AS seating_date, " \
    "to_char(b.seating_at AT TIME ZONE 'Europe/Lisbon', 'HH24:MI')    AS seating_time, " \
    "b.seating_at " \
    "FROM bookings b " \
    "JOIN restaurant_tables rt ON rt.id = b.restaurant_table_id " \
    "JOIN restaurants r        ON r.id  = b.restaurant_id " \
    "WHERE b.user_id = kiosk.current_user_id() " \
    "ORDER BY b.seating_at"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

# book_table — reserve a specific table at a chosen restaurant for a chosen
# upcoming seating, for the authenticated principal. The (restaurant_id,
# restaurant_table_id) come from an availability row; the seating is
# (date, time). The seating must be one of the CURRENT upcoming seatings (not
# past — re-validated against lib/seatings.rb). Contention is finite: a UNIQUE
# index on (restaurant_table_id, seating_at) among confirmed rows means a table
# already held for that seating is a clean 409 Conflict. No payment — a
# reservation takes no money (any deposit shown is settled at the restaurant).
Kiosk::Server::Actions.register("book_table",
                                  description: "Book a specific restaurant table for a chosen upcoming " \
                                               "seating (params: restaurant_id, restaurant_table_id, date, " \
                                               "time, party_size — all from an availability row). Confirms " \
                                               "the reservation; a table already taken for that seating, or a " \
                                               "seating that has passed, is rejected cleanly.",
                                  params: {
                                    restaurant_id:       "integer — the restaurant_id from an availability row",
                                    restaurant_table_id: "integer — the restaurant_table_id from an availability row",
                                    date:                "string — the seating_date (YYYY-MM-DD) from the availability row",
                                    time:                "string — the seating_time HH:MM (24-hour), e.g. \"20:00\"",
                                    party_size:          "integer — number of guests (must fit the table's capacity)",
                                  },
                                  input_schema: {
                                    type: "object",
                                    additionalProperties: false,
                                    properties: {
                                      restaurant_id:       { type: "integer", minimum: 1,
                                                             description: "The restaurant_id from an availability row." },
                                      restaurant_table_id: { type: "integer", minimum: 1,
                                                             description: "The restaurant_table_id from an availability row." },
                                      date:                { type: "string", format: "date",
                                                             description: "The seating_date (YYYY-MM-DD) from the availability row." },
                                      time:                { type: "string", pattern: "^[0-2][0-9]:[0-5][0-9]$",
                                                             description: "The seating_time HH:MM (24-hour), e.g. \"20:00\"." },
                                      party_size:          { type: "integer", minimum: 1,
                                                             description: "Number of guests." },
                                    },
                                    required: ["restaurant_id", "restaurant_table_id", "date", "time", "party_size"],
                                  },
                                  example_params: {
                                    restaurant_id: 1, restaurant_table_id: 1,
                                    date: "2026-08-08", time: "20:00", party_size: 2,
                                  },
                                  example_row: {
                                    booking_id: "b1f2a3c4-5d6e-4f70-8a91-2b3c4d5e6f70",
                                    restaurant_id: 1, restaurant_table_id: 1, party_size: 2,
                                    date: "2026-08-08", time: "20:00",
                                    seating_at: "2026-08-08T20:00:00+01:00", status: "confirmed",
                                  }) do |args|
  conn = ActiveRecord::Base.connection

  restaurant_id       = (args[:restaurant_id]       || args["restaurant_id"]).to_i
  restaurant_table_id = (args[:restaurant_table_id] || args["restaurant_table_id"]).to_i
  date                = (args[:date]                || args["date"]).to_s
  time                = (args[:time]                || args["time"]).to_s
  party_size          = (args[:party_size]          || args["party_size"]).to_i
  raise Kiosk::Server::Errors::BadRequest.new("missing param: restaurant_id")       if restaurant_id < 1
  raise Kiosk::Server::Errors::BadRequest.new("missing param: restaurant_table_id") if restaurant_table_id < 1
  raise Kiosk::Server::Errors::BadRequest.new("missing param: date")                if date.empty?
  raise Kiosk::Server::Errors::BadRequest.new("missing param: time")                if time.empty?
  raise Kiosk::Server::Errors::BadRequest.new("party_size must be >= 1")             if party_size < 1

  # The seating instant, from the SAME helper availability used. Reject a seating
  # that is not one of the current upcoming ones (past / wrong time), so an agent
  # can't book a window availability would now hide.
  parsed_date =
    begin
      Date.iso8601(date)
    rescue ArgumentError
      raise Kiosk::Server::Errors::BadRequest.new("invalid date: #{date} — use the YYYY-MM-DD from an availability row")
    end
  raise Kiosk::Server::Errors::BadRequest.new("unknown seating time: #{time} — use \"19:00\" | \"20:00\" | \"21:00\"") unless Seatings::TIMES.include?(time)
  if Seatings.past?(parsed_date, time)
    raise Kiosk::Server::Errors::BadRequest.new(
      "seating #{date} #{time} has already started — call availability again for the still-bookable seatings"
    )
  end
  seating_at = Seatings.seating_at(parsed_date, time)

  # Identity is set via Kiosk::Server::SessionContext SET LOCAL —
  # current_user_id() returns the principal. ActiveRecord doesn't have direct
  # access; pull from PG.
  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]

  conn.transaction do
    # The chosen table must exist at the chosen restaurant and seat the party.
    table = conn.execute(
      "SELECT rt.id, rt.capacity FROM restaurant_tables rt " \
      "WHERE rt.id = #{restaurant_table_id} AND rt.restaurant_id = #{restaurant_id} " \
      "AND rt.capacity >= #{party_size} " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::BadRequest.new("no such table #{restaurant_table_id} at restaurant #{restaurant_id} seating #{party_size}") if table.nil?

    # Finite contention: is this exact (table, seating) already held? A clean
    # 409 Conflict, mirrored by the unique partial index (the index is the
    # authoritative guard even under concurrency).
    held = conn.execute(
      "SELECT 1 FROM bookings WHERE status = 'confirmed' " \
      "AND restaurant_table_id = #{restaurant_table_id} " \
      "AND seating_at = #{conn.quote(seating_at.iso8601)}::timestamptz LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Conflict.new("table #{restaurant_table_id} is already booked for #{date} #{time}") if held

    booking =
      begin
        conn.execute(
          "INSERT INTO bookings " \
          "(id, user_id, restaurant_id, restaurant_table_id, party_size, seating_at, status, created_at, updated_at) " \
          "VALUES (gen_random_uuid(), #{conn.quote(uid.to_s)}::uuid, #{restaurant_id}, #{restaurant_table_id}, " \
          "#{party_size}, #{conn.quote(seating_at.iso8601)}::timestamptz, 'confirmed', now(), now()) " \
          "RETURNING id, party_size, status"
        ).first
      rescue ActiveRecord::RecordNotUnique
        # Lost a race for the same (table, seating) — the unique index caught it.
        raise Kiosk::Server::Errors::Conflict.new("table #{restaurant_table_id} is already booked for #{date} #{time}")
      end

    {
      booking_id:          booking["id"],
      restaurant_id:       restaurant_id,
      restaurant_table_id: restaurant_table_id,
      party_size:          booking["party_size"].to_i,
      date:                date,
      time:                time,
      seating_at:          seating_at.iso8601,
      status:              booking["status"],
    }
  end
end

# cancel_booking — cancel one of the authenticated principal's own bookings,
# freeing the (table, seating) so it can be booked again. Owner-scoped: the
# WHERE gates on user_id = kiosk.current_user_id(), so a cross-principal cancel
# on another's booking is a clean 403 (the booking is not found under the
# caller's identity).
Kiosk::Server::Actions.register("cancel_booking",
  description: "Cancel one of the authenticated principal's own table bookings " \
               "(requires the booking to belong to the principal). Frees the (table, seating).",
  params: {
    booking_id: "uuid — the booking to cancel (from book_table / my_bookings; must belong to the principal)",
  }) do |args|
  conn = ActiveRecord::Base.connection

  booking_id = args[:booking_id] || args["booking_id"]
  raise Kiosk::Server::Errors::BadRequest.new("missing field: booking_id") if booking_id.nil? || booking_id.to_s.empty?

  conn.transaction do
    # Owner-scoped: the booking must belong to the caller and not be cancelled.
    booking = conn.execute(
      "SELECT id FROM bookings " \
      "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id() " \
      "AND status <> 'cancelled' " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Forbidden.new("booking not found, not yours, or already cancelled") if booking.nil?

    # Cancelling drops the row out of the confirmed set, so the unique partial
    # index frees the (table, seating) for a fresh booking.
    conn.execute(
      "UPDATE bookings SET status = 'cancelled', updated_at = now() " \
      "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id()"
    )

    { booking_id: booking_id, status: "cancelled" }
  end
end
