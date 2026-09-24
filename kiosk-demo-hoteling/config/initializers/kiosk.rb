# frozen_string_literal: true

# hoteling — hotel booking with a payment gate. No KYC, no hardware unlock.
# Queries: properties, availability, my_bookings, search_hotels, hotel_detail
# Actions: reserve_room, confirm_booking, payment_setup
#
# TWO PoW gates run here and their default postures are OPPOSITE: the BROWSE
# toll is OFF unless KIOSK_POW_BROWSE_DEMO=1, the REGISTRATION gate is ALWAYS
# ON with no env flag to forget. Each has its own section below.
#
# Env posture (signing key, PoW secret, issuer, test flags) lives in
# config/environments/*; this file reads Rails.configuration.x.kiosk.*.

require "kiosk/user_identity_providers/devise"

# ── Browse-heavy PoW demo (KIOSK_POW_BROWSE_DEMO=1) ───────────────────────
#
# Hotel search is browse-heavy: an assistant comparing options runs many
# `availability` queries, and that is legitimate — indistinguishable from
# scraping by pattern alone. So this vertical does NOT treat browsing as
# suspicion. It PRICES BY REQUEST RATE: the first few queries are free, then
# each extra costs escalating proof-of-work. An assistant pays seconds of
# compute to look deeper; a bulk scraper pays linearly and forever.
#
# The rate is tracked per agent IN-PROCESS — demo only; a real provider needs a
# shared counter or sliding window. Params follow KIOSK_POW_DIFFICULTY
# (Kiosk::Pow::Equihash::Difficulty): low (default) → n=96 k=5, sub-second;
# high → n=168 k=7, ~1.3 GiB and ~10s on the reference numpy solver.
require "kiosk/pow/equihash"
EQUIHASH_BROWSE_PARAMS = Kiosk::Pow::Equihash::Difficulty.params
HOTELING_FREE_BROWSES  = 3    # first N availability queries are free
HOTELING_RATE_STEP     = 2    # +1 proof per this many queries beyond the free tier
HOTELING_MAX_PROOFS    = 5
HOTELING_WRITE_PROOFS  = 1    # flat toll on an action (`:run`) — a hold, not a read

# ── Registration PoW gate — ALWAYS ON ───────────────────────────────────────
#
# register is a verb like any other: a hotel provider prices fresh-identity
# minting (one Equihash proof) so a scraper renting throwaway agents pays at the
# door. Independent of the browse-rate gate above, and there is no env flag to
# forget. The require + Backends.register below run UNCONDITIONALLY (both
# idempotent) so the gate works regardless of KIOSK_POW_BROWSE_DEMO — else
# RegistrationPow.gate raises ConfigurationError at register.
HOTELING_REGISTRATION_POW_PARAMS = Kiosk::Pow::Equihash::Difficulty.params
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

if ENV["KIOSK_POW_BROWSE_DEMO"] == "1"
  HOTELING_BROWSE_COUNT = Hash.new(0)  # agent_id => availability queries so far

  # Priced-pagination policy: free below the allowance, then proof count rises
  # with the query rate. The policy is advertised for a POLICY KIND — one of
  # `Kiosk::Server::Executor::VERBS`, not a wire path.
  #
  # ── THE NAME OF THE WRITE KIND IS `:run`, NOT `:action` ────────────────────
  #
  # What an operator DECLARES above a handler is `kind :query` / `kind :action`;
  # what this hook RECEIVES is one of `Executor::VERBS` — `%i[query run pay]`.
  # An `action` therefore arrives here as `:run`, and `pay` as its own third
  # kind. `:query` is spelled the same in both, which hides the mismatch.
  # A wrong branch is SILENT: `challenge_for` returning nil is the ordinary «do
  # not toll this one» answer, so `verb == :action` never raises and never logs
  # — the toll simply never applies to writes and the origin looks configured.
  #
  # Writes are priced because `reserve_room` holds real inventory: depth costs
  # escalating proofs, a HOLD costs a flat one, because the thing being rationed
  # is the room and not the reading. `:pay` is deliberately NOT tolled — the
  # toll belongs before a settlement, not on it.
  class HotelingBrowsePolicy < Kiosk::Reputation::Policy
    def initialize(params)
      @params = params
    end

    def challenge_for(identity:, verb:, factors:)
      # `:run` is the WRITE kind — see the vocabulary note above before changing
      # this to `:action`, which this hook never receives.
      return { alg: Kiosk::Pow::Equihash::NAME, params: @params, count: HOTELING_WRITE_PROOFS } if verb == :run
      return nil unless verb == :query

      rate = factors.request_rate_per_min.to_i
      return nil if rate <= HOTELING_FREE_BROWSES

      over  = rate - HOTELING_FREE_BROWSES
      count = [(over + HOTELING_RATE_STEP - 1) / HOTELING_RATE_STEP, HOTELING_MAX_PROOFS].min
      { alg: Kiosk::Pow::Equihash::NAME, params: @params, count: count }
    end
  end
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
  # development reload so an edited verb needs no restart. A verb registers when
  # its class LOADS and nothing loads a handler on its own, so an origin whose
  # controllers are not named here serves NOTHING.
  c.handlers = %w[Kiosk::HotelsController Kiosk::ReservationsController]

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

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
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. A
  # "beware: intensive PoW" notice appears only when KIOSK_POW_DIFFICULTY=high
  # (hoteling ships low, so normally absent).
  c.owner  = { name: "hoteling", support: "demo@kiosk.tech" }
  if (notice = Kiosk::Pow::Equihash::Difficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: Kiosk::Pow::Equihash::Difficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.4.15.md"
  c.skill_sha256 = "2fe8e083e09f1763fd40ea238ec6e9bc1470b57f893f4be2cec0702fe5173f5d"

  # ── NO c.agent_idp — deliberate ──────────────────────────────────────────
  # An assistant authenticates with the kiosk-pop JWT this engine minted, and
  # the engine verifies its own tokens: `IdentityResolution.agent_idp` falls
  # back to `AgentIdentityProviders::DefaultAgentIdp` when nothing is set.
  # SET IT only to front an EXTERNAL agent-identity issuer, by subclassing
  # `Kiosk::AgentIdentityProviders::Base` — whose one hard constraint is that
  # the `agent_id` it returns must be a UUID.
  #
  # user_idp is the provider's own web session (Devise/Warden): it authenticates
  # the approving human on the account-binding surfaces — device verify page,
  # link-code mint, unlink.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new

  # The cashier check: ValidatingBookingProvider verifies the agent-signed
  # cart against OUR quote — currency (EUR), single booking reference, and the
  # total the operator quoted for that booking — before the wrapped StubPsp
  # captures anything. Monetary only: booking→payer ownership is enforced at
  # USE time (confirm_booking Gate-1), not here.
  c.payment_provider = ValidatingBookingProvider.new(StubPsp.new, currency: "eur")

  # ── Per-assistant spending cap ───────────────────────────────────────────
  # Reads the cap from `kiosk.agents.spending_cap_cents`, the nullable column
  # every demo's identity migration declares. Null means uncapped.
  #
  # A SEAM NOBODY CONFIGURES IS NOT A CONTROL: `Executor#enforce_spending_cap!`
  # returns at its first line when this is unset, so an origin that leaves it
  # out has no cap at all, silently. `demo:spending_cap` writes a cap and
  # watches it bite.
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

  # ── Registration PoW gate — ALWAYS ON ────────────────────────────────────
  # Registering an agent costs ONE Equihash proof. pow_secret is assigned
  # unconditionally so the gate still works when KIOSK_POW_BROWSE_DEMO is off —
  # RegistrationPow.gate raises without it.
  c.registration_pow_count  = 1
  c.registration_pow_params = HOTELING_REGISTRATION_POW_PARAMS
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

# Amenity vocabulary — the closed set a property MAY offer. Shared by the
# search_hotels `amenity` filter enum (Kiosk::HotelsController) and the seeds
# (db/seeds.rb), so the descriptor and the data cannot disagree. It stays in the
# initializer because the seeds read it before any model is involved, and
# because an initializer constant is available by the time the handler class
# body is read.
AMENITY_POOL = %w[wifi breakfast pool spa gym parking rooftop_bar
                  airport_shuttle sea_view pet_friendly restaurant hammam].freeze

# Served-area vocabulary — the districts this operator sells in. Same shape and
# reason as AMENITY_POOL.
#
# A CONSTANT AND NOT A PROC OVER THE INVENTORY: deriving the enum from
# `properties.neighbourhood` would narrow it to the districts that HAPPEN to
# have inventory right now, collapsing "we do not serve that area" (a 400 naming
# the served set) into "no hotel there today" (a 200 []). Derive an enum from a
# VOCABULARY, never from a column on an INVENTORY table.
NEIGHBOURHOOD_POOL = %w[Sultanahmet Beyoğlu Kadıköy Beşiktaş Şişli Fatih
                        Üsküdar Galata Taksim Ortaköy Bakırköy Nişantaşı].freeze
