# frozen_string_literal: true

# getgrocery — a single grocery provider, no store layer. The catalog exposes
# in-stock facts; the assistant makes the substitution decisions.
#
# Queries:  catalog, delivery_slots (delivery ADDRESS/zone REQUIRED — validated
#           against served Dublin districts), my_orders
# Actions:  create_order (delivery slot + address REQUIRED), reschedule_delivery;
#           kiosk-server serves payment_setup and request_kyc
# Pay:      capture is wrapped by Kiosk::Server::PaymentClaim — the cart must be
#           EUR, reference the payer's unsettled order, mirror its items at
#           catalog prices (app/services/price_checker.rb), and sum correctly.
#
# ADDRESS-UPFRONT: the delivery address is a deliberate, EARLY input.
# `delivery_slots` returns no slots without an in-zone Dublin address, so the
# assistant must get the address from its human BEFORE it can shop, and
# `create_order` re-validates the same zone rule. The operator validates FORMAT
# and ZONE only — it CANNOT verify that a plausible in-zone address is real; the
# human confirming it is the ceiling.
#
# Env posture (signing key, PoW secret, issuer, Stripe credentials, test flags)
# lives in config/environments/*; this file reads
# Rails.configuration.x.kiosk.* and never ENV.

require "kiosk/payment_providers/stripe"
require "kiosk/kyc_providers/prove"
require "kiosk/user_identity_providers/devise"

# ── Query toll ──────────────────────────────────────────────────────────────
#
# A grocery provider tolls every query to price anonymous browsing of its
# catalog — a metered toll, not a wall. run/pay are never gated. Params follow
# KIOSK_POW_DIFFICULTY (Kiosk::Pow::Equihash::Difficulty): low (default) →
# n=96 k=5, sub-second; high → n=168 k=7, ~1.3 GiB and ~10s on the reference
# numpy solver.
require "kiosk/pow/equihash"
EQUIHASH_DEMO_PARAMS = Kiosk::Pow::Equihash::Difficulty.params

# ── Registration PoW gate — ALWAYS ON ───────────────────────────────────────
#
# register is a verb like any other: a grocery provider prices fresh-identity
# minting (one Equihash proof) so spam signups pay at the door.
GETGROCERY_REGISTRATION_POW_PARAMS = Kiosk::Pow::Equihash::Difficulty.params
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

# ⚠ TOY COUNTER — NOT a reputation signal. Nothing reads it for policy
# (`reputation_factors` below is `Factors.empty`); it exists so
# `script/pow_flow.rb` can print "the server counted MY bad proof". Keyed per
# identity in sqlite (app/services/bad_proof_counter.rb), so one abuser cannot
# inflate anyone else's count. It has NO TTL, and a count that only grows is
# equally wrong: a production signal needs decay and durability first.
#
# `rake check:pow` owns the file's location — it wipes it and exports
# KIOSK_BAD_PROOF_DB to both the server and the driver, so the two cannot
# drift onto different files and report zero at each other.
GETGROCERY_BAD_PROOF_DB = Rails.configuration.x.kiosk.bad_proof_db

class GetgroceryQueryPowPolicy < Kiosk::Reputation::Policy
  def initialize(params)
    @params = params
  end

  def challenge_for(identity:, verb:, factors:)
    return nil unless verb == :query

    { alg: Kiosk::Pow::Equihash::NAME, params: @params }
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
  c.roles  = %i[customer]

  # ── The wire surface ──────────────────────────────────────────────────────
  # The operator NAMES its handler controllers; the engine loads and registers
  # them on every `to_prepare` pass. Nothing in a host app references a handler
  # on its own — the wire reaches it THROUGH the registry — so an unnamed class
  # is never autoloaded, the registry stays empty, and `/.well-known/kiosk.json`
  # advertises no capabilities at all.
  c.handlers = %w[Kiosk::StorefrontController Kiosk::OrdersController]

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
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. A
  # "beware: intensive PoW" notice appears only when KIOSK_POW_DIFFICULTY=high
  # (getgrocery ships low, so normally absent).
  c.owner  = { name: "GetGrocery", support: "demo@kiosk.tech" }
  if (notice = Kiosk::Pow::Equihash::Difficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: Kiosk::Pow::Equihash::Difficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.5.10.md"
  c.skill_sha256 = "5f4f84d26449fc645d2f725a2e60f88126f619bf68c35a37a1379b2b9dff13c7"

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
  # link-code mint, unlink. `rake check:claim` walks the claim-rebind ceremony.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  # Where the engine bounces an unauthenticated browser visitor to the
  # account-binding pages. The engine stays IdP-neutral, so the URL is
  # supplied here; without it those pages render a bare 401.
  c.sign_in_path = "/users/sign_in"

  # Payment provider: real Stripe in test mode (sk_test_…), SetupIntent
  # card-on-file — card saved once on Stripe's hosted page, charged off_session
  # per purchase. The principal→Stripe Customer mapping is the adapter's own
  # `stripe_customers` table (Kiosk::PaymentProviders::Stripe::CustomerRecord).
  #
  # CREDENTIALS COME FROM THE ENVIRONMENT FILE, NOT FROM ENV, so there is no
  # `Rails.env` branch here.
  #
  # Real Stripe by default (check:shop → a real pi_…). When a mock base URL is
  # configured — the adversarial suites, and CI, which carries no key — point
  # the SDK at a local stripe-mock instead: shaped fixtures, so the full
  # pay→settlement flow and the Kiosk ownership and settlement-exists gates run
  # end to end without hitting Stripe. `Stripe.api_base` is SDK state rather
  # than configuration, so it is set here, where the adapter is built.
  key = Rails.configuration.x.kiosk.stripe_secret_key
  if (mock = Rails.configuration.x.kiosk.stripe_mock_url).present?
    require "stripe"
    Stripe.api_base = mock                          # e.g. http://127.0.0.1:12111
  end
  # Dev and test resolve a key unconditionally, so a blank one here means
  # production started without a payment credential — and an origin that
  # ADVERTISES `pay` and then cannot charge is worse than one that will not boot.
  raise "getgrocery requires STRIPE_SECRET_KEY (sk_test_…) or STRIPE_MOCK_URL" if key.blank?

  # test_autocard (set by the demo/redteam/isolation rake tasks via
  # KIOSK_TEST_AUTOCARD=1) makes the adapter simulate a completed SetupIntent —
  # automated suites need no card-setup step and no server-side test route.
  # config/environments/production.rb pins it FALSE, so the live demo
  # always runs the real hosted SetupIntent flow (human enters the card once).
  # One capture per order, owner-scoped, and the cart checked against OUR
  # catalog (app/services/price_checker.rb) before Stripe captures anything.
  c.payment_provider = Kiosk::Server::PaymentClaim.new(
    Kiosk::PaymentProviders::Stripe.new(
      api_key:       key,
      test_autocard: Rails.configuration.x.kiosk.test_autocard,
    ),
    currency: "eur", table: "orders", reference: "order_id", query: "my_orders",
    status_column: "status", unpaid: "created", owner_column: "user_id",
  )
  c.cart_price_checker = PriceChecker
  # The basket is bought; from here the shop acts on its own clock.
  c.after_payment      = ->(order_id) { CourierDispatchJob.arm!(order_id) }

  # ── KYC — the shared Prove broker ────────────────────────────────────
  # create_order refuses a cart with an age_restricted item until the person
  # holds age_over_18. The broker public key and intake secret come from
  # config/environments with no shipped fallback; without the secret this
  # origin serves no KYC.
  prove_operator   = "getgrocery"
  prove_secret     = Rails.configuration.x.kiosk.prove_intake_secret
  c.kyc_provider   = Kiosk::KycProviders::Prove.new(operator_id: prove_operator, intake_secret: prove_secret) if prove_secret.present?
  c.kyc_claims     = %w[age_over_18]
  c.kyc_issuer     = Kiosk::KycProviders::Prove.issuer
  c.kyc_public_key = Rails.configuration.x.kiosk.prove_public_key_pem
  c.kyc_audience   = prove_operator

  # ── Query toll ───────────────────────────────────────────────────────────
  c.reputation_policy  = GetgroceryQueryPowPolicy.new(Kiosk::Pow::Equihash.params(**EQUIHASH_DEMO_PARAMS))
  c.pow_ttl            = 300
  c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }
  # ⚠ TOY COUNTER — the write side of the demo counter defined above; the
  # caveat there applies verbatim (no TTL). PER IDENTITY: keyed by the
  # verified agent credential id the gate hands in, so one abuser's
  # rejections never appear in anyone else's count. Its only consumer is the
  # local driver script/pow_flow.rb; `reputation_factors` right above feeds
  # the policy `Factors.empty`, so nothing this counts changes any toll.
  c.on_bad_proof = ->(identity:) {
    BadProofCounter.increment(GETGROCERY_BAD_PROOF_DB, identity.agent_id)
  }

  # ── Registration PoW gate — ALWAYS ON ────────────────────────────────────
  # Price fresh-identity minting: registering an agent costs ONE Equihash proof.
  # The query toll above signs its challenges with the same pow_secret.
  c.registration_pow_count  = 1
  c.registration_pow_params = GETGROCERY_REGISTRATION_POW_PARAMS
  c.pow_secret              = pow_secret

  # ── The event tail lives in the DATABASE, not in this process ────────────
  # The operator keeps every event for 24 hours, so a subscriber that
  # reconnects with `since` set to the last id it saw misses nothing. An
  # in-process tail would lose the events inside that window on every restart
  # and deploy. Same seam as `pow_spent_store` above, opposite call.
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
