# frozen_string_literal: true

# Kiosk-demo (hoteling-shape) configuration. Hotel booking with payment gate.
# No KYC, no hardware unlock. TWO PoW gates run here and their default postures
# are OPPOSITE: the BROWSE toll is off by default and switched on with
# KIOSK_POW_BROWSE_DEMO=1, which prices the browse-heavy QUERY endpoints by
# request rate with escalating Equihash proofs, sized by whatever
# KIOSK_POW_DIFFICULTY selects (see the browse gate below, exercised by
# demo:browse); the REGISTRATION gate is ALWAYS ON, with no env flag to set or
# to forget. Each gate's own section below owns its detail; neither is restated
# here.
#
# NAMING THE GATE IS THE POINT OF THAT SENTENCE (K-1041). It used to make the
# off-by-default claim about this origin's PoW posture AS A WHOLE, flat out, and
# only then narrow to the browse flag — and the file contradicts that reading in
# every place further down where it states the register gate's own posture
# («ALWAYS ON — POW-VERB-GATING», «ALWAYS ON (register is uniformly tolled)»,
# «so register-pow works regardless of KIOSK_POW_BROWSE_DEMO»). Those are what
# the code does: `registration_pow_count` and `registration_pow_params` are
# assigned inside `Kiosk.configure` and OUTSIDE the
# `if ENV["KIOSK_POW_BROWSE_DEMO"]` branch, so they take effect with the flag
# unset. Which gate is off is the first thing a reader learns about a demo's
# posture, so the claim has to name the gate it is true of. The old phrasing is
# deliberately not retyped here, so a grep for it finds live claims only.
#
# NO (n, k) IS NAMED IN THIS OPENING BLOCK (K-1038, the K-1035 class). This
# sentence used to state a pair outright, unconditionally, while
# `EQUIHASH_BROWSE_PARAMS = PowDifficulty.params` further down reads that pair
# out of the environment — so `KIOSK_POW_DIFFICULTY=high` made the first thing a
# reader of this file sees FALSE, with no edit to this tree, and that setting is
# not hypothetical (deploy/env/atablefor.env.example ships it for a sibling
# demo). A comment cannot read a value, so the repair is to NAME THE KNOB; the
# mapping from knob to params stays written out exactly once, beside the
# constant it governs, and the register half below states which level hoteling
# ships. The escalation claim itself is untouched and real: it is
# HOTELING_FREE_BROWSES / HOTELING_RATE_STEP / HOTELING_MAX_PROOFS.
# Queries: properties, availability, my_bookings, search_hotels, hotel_detail
# Actions: reserve_room, confirm_booking, payment_setup
#
# The verbs THEMSELVES are not here any more (T-057 / K-654): they are Rails
# controllers under app/controllers/kiosk/, named in `c.handlers` below, and
# their writes are Operations under app/operations/. What is left in this file is
# configuration — the PoW gates, the payment provider, the identity providers —
# which is what an initializer is for.

# Env posture (ephemeral dev signing key, PoW secret, issuer, test flags) lives
# in config/environments/{development,test,production}.rb (K-650); this file
# reads the resolved values from Rails.configuration.x.kiosk.*.


require "kiosk/user_identity_providers/devise"

# ── Browse-heavy PoW demo (KIOSK_POW_BROWSE_DEMO=1) ───────────────────────
#
# Hotel search is browse-heavy: an assistant comparing options runs many
# `availability` queries, and that is legitimate — indistinguishable from
# scraping by pattern alone. So this vertical does NOT treat browsing as
# suspicion. It PRICES BY REQUEST RATE (a coarse proxy for depth): the first
# few queries are free, then each extra query costs escalating proof-of-work
# (metered pricing, not a wall). A human's assistant pays a few
# seconds of compute to look deeper; a bulk scraper pays linearly and forever.
# (The offset/page-precise "metered pagination" variant is deferred;
# this rate-based form needs no change to the reputation Factors interface.)
#
# The rate is tracked per agent in-process (demo only — a real provider uses a
# shared counter / sliding window). EQUIHASH_BROWSE_PARAMS follow
# KIOSK_POW_DIFFICULTY (app/services/pow_difficulty.rb): low (default) → n=96 k=5
# sub-second; high → n=168 k=7 (~1.3 GiB per proof, and ~10s on the reference
# numpy solver as measured on one M-series laptop core). hoteling ships low; the
# knob is here for parity across the hosted apps. Unset = low.
EQUIHASH_BROWSE_PARAMS = PowDifficulty.params
HOTELING_FREE_BROWSES  = 3    # first N availability queries are free
HOTELING_RATE_STEP     = 2    # +1 proof per this many queries beyond the free tier
HOTELING_MAX_PROOFS    = 5

# ── Registration PoW gate — ALWAYS ON — POW-VERB-GATING (K-487)
#
# register is a verb like any other: a hotel provider prices fresh-identity
# minting (one Equihash proof) so a scraper renting throwaway agents pays at the
# door. Independent of the browse-rate gate above. Register is now uniformly
# tolled on every demo (no per-demo env flag to remember): it activates on
# code-deploy and can't be forgotten. Params follow KIOSK_POW_DIFFICULTY
# (hoteling ships low → n=96 k=5 sub-second). The gate requires the Equihash
# backend registered; the require + Backends.register run UNCONDITIONALLY here
# (both idempotent) so register-pow works regardless of KIOSK_POW_BROWSE_DEMO —
# else RegistrationPow.gate raises ConfigurationError at register.
HOTELING_REGISTRATION_POW_PARAMS = PowDifficulty.params
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

if ENV["KIOSK_POW_BROWSE_DEMO"] == "1"
  HOTELING_BROWSE_COUNT = Hash.new(0)  # agent_id => availability queries so far

  # Priced-pagination policy: free below the allowance, then proof count rises
  # with the query rate. Only reads are priced — the policy is advertised for
  # the `:query` POLICY KIND (Executor::VERBS, the coarse kind of a call, not a
  # wire path), so every `GET /kiosk/<query-name>` is tolled and actions and
  # `pay` are never gated here.
  class HotelingBrowsePolicy < Kiosk::Reputation::Policy
    def initialize(params)
      @params = params
    end

    def challenge_for(identity:, verb:, factors:)
      return nil unless verb == :query
      rate = factors.request_rate_per_min.to_i
      return nil if rate <= HOTELING_FREE_BROWSES

      over  = rate - HOTELING_FREE_BROWSES
      count = [(over + HOTELING_RATE_STEP - 1) / HOTELING_RATE_STEP, HOTELING_MAX_PROOFS].min
      { alg: Kiosk::Pow::Equihash::NAME, params: @params, count: count }
    end
  end
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
  # The five queries and three actions are ordinary Rails controllers under
  # app/controllers/kiosk/ — `include Kiosk::Handler`, class-level macros (`kind`
  # says which verb reaches each one), plain `render json:`. Nothing about them belongs in an
  # initializer, and nothing about them is here: this line only NAMES them, and
  # the engine loads and registers them (once in production, again after every
  # reload in development, so an edited/added/removed verb needs no restart).
  # A verb registers when its class LOADS and nothing loads a handler on its own,
  # so an origin whose controllers are not named here serves nothing at all
  # (K-761).
  c.handlers = %w[Kiosk::HotelsController Kiosk::ReservationsController]

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

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
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. A
  # "beware: intensive PoW" notice appears only when KIOSK_POW_DIFFICULTY=high
  # (hoteling ships low, so normally absent).
  c.owner  = { name: "hoteling", support: "demo@kiosk.tech" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.4.10.md"
  c.skill_sha256 = "679f108333fdf17833948f404d8faa58e6f50df034949d2c7c77139a46f59c27"

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
  # approving human on the account-binding surfaces — the device verify page,
  # link-code mint and unlink. ONE channel in every environment: there is no
  # dev-only arm to gate, because there is no stub left to gate (T-066).
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new

  # The cashier check: ValidatingBookingProvider verifies the agent-signed
  # cart against OUR quote — currency (EUR), single booking reference, and the
  # total the operator quoted for that booking — before the wrapped StubPsp
  # captures anything. Monetary only: booking→payer ownership is enforced at
  # USE time (confirm_booking Gate-1), not here.
  c.payment_provider = ValidatingBookingProvider.new(StubPsp.new, currency: "eur")

  # ── Per-assistant spending cap (T-154) ───────────────────────────────────
  # The batteries-included seam: read the cap from `kiosk.agents
  # .spending_cap_cents`, the nullable column every demo's identity migration
  # already declares. Null means uncapped, so this line changes nothing for any
  # assistant nobody has capped — including every one the other tasks in this
  # demo register — and `demo:spending_cap` is where a cap is actually written
  # and the control actually bites.
  #
  # IT IS HERE RATHER THAN NOWHERE BECAUSE «NOWHERE» WAS THE STATE OF THE WHOLE
  # FLEET, AND THAT COST SOMETHING. `Executor#enforce_spending_cap!` returns at
  # its first line when this is unset, so until this line existed no demo and
  # no e2e origin exercised the control at all — which is precisely what let
  # K-1251 sit unseen: a cap the assistant could defeat by alternating the
  # capitalisation of its currency, live for any operator who configured the
  # seam and for nobody here. hoteling is the host because it is one of the
  # three origins that can actually settle (kiosk-demo-stylish reasons its way
  # to the opposite conclusion for the opposite reason — it configures no
  # `payment_provider`, so a `pay` there is refused before a cart exists).
  c.spending_cap = Kiosk::Server::ColumnSpendingCap.new

  # ── Browse-heavy priced-pagination gate (KIOSK_POW_BROWSE_DEMO=1) ────────
  if ENV["KIOSK_POW_BROWSE_DEMO"] == "1"
    c.reputation_policy = HotelingBrowsePolicy.new(EQUIHASH_BROWSE_PARAMS)
    c.pow_ttl           = 300

    # Factors: count availability queries per agent in-process and report the
    # running total as the "rate". Only `query` is counted (browsing depth).
    c.reputation_factors = ->(identity:, verb:) {
      if verb == :query
        HOTELING_BROWSE_COUNT[identity.agent_id] += 1
      end
      Kiosk::Reputation::Factors.new(
        kyc_level: nil, settled_purchases_count: nil, settled_purchases_cents: nil,
        request_rate_per_min: HOTELING_BROWSE_COUNT[identity.agent_id],
        account_age_seconds: nil, dispute_count: nil, bad_proof_count: 0,
      )
    }
  end

  # ── Registration PoW gate — ALWAYS ON (register is uniformly tolled) ──────
  # Price fresh-identity minting: registering an agent costs ONE Equihash proof.
  # Independent of the browse gate above; pow_secret is set unconditionally so the
  # gate works even when KIOSK_POW_BROWSE_DEMO is off (RegistrationPow.gate raises
  # without it) — the browse-gate branch above shares this one assignment.
  c.registration_pow_count  = 1
  c.registration_pow_params = HOTELING_REGISTRATION_POW_PARAMS
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

# Amenity vocabulary — the closed set a property MAY offer. Shared by the
# search_hotels `amenity` filter enum (Kiosk::HotelsController) and the seeds
# (db/seeds.rb), so the descriptor and the data cannot disagree about what an
# amenity is. It stays in the initializer rather than moving onto Property
# because the seeds read it before any model is involved, and because an
# initializer constant is available by the time the handler class body is read
# (initializers run before eager-load, and before the engine's `to_prepare`
# rebuild in development).
AMENITY_POOL = %w[wifi breakfast pool spa gym parking rooftop_bar
                  airport_shuttle sea_view pet_friendly restaurant hammam].freeze

# Served-area vocabulary — the districts this operator sells in. Same shape and
# same reason as AMENITY_POOL: shared by the search_hotels `neighbourhood` filter
# enum (Kiosk::HotelsController) and the seeds (db/seeds.rb), so a rename or a
# typo in either place cannot leave a value the filter can never reach.
#
# WHY IT IS A CONSTANT AND NOT A K-922 PROC (T-090, K-947). Deriving the enum
# from `properties.neighbourhood` would narrow it to the districts that HAPPEN to
# have inventory right now, which collapses "we do not serve that area" (a 400
# naming the served set) into "no hotel there today" (a 200 []) — a distinction
# T-090 drew on purpose and `app/operations/operation_result.rb` records. The
# rule the K-922 sweep settled: derive an enum from a VOCABULARY table, never
# from a column on an INVENTORY table. This is the vocabulary, written down.
NEIGHBOURHOOD_POOL = %w[Sultanahmet Beyoğlu Kadıköy Beşiktaş Şişli Fatih
                        Üsküdar Galata Taksim Ortaköy Bakırköy Nişantaşı].freeze

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  HOTELING_VERB_MAP = {
    "reserve_room"    => "reserved",
    "confirm_booking" => "booked",
    "payment_setup"   => "ran",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: HOTELING_VERB_MAP,
  )
end
