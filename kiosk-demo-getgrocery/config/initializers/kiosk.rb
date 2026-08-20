# frozen_string_literal: true

# Kiosk-demo (getgrocery-shape) configuration.
# Single grocery provider — no store layer. Catalog exposes in-stock facts;
# the AI assistant handles substitution decisions.
# Queries:  catalog, delivery_slots (delivery ADDRESS/zone REQUIRED — validated
#           against served Dublin districts), my_orders, kyc_status
# Actions:  create_order (delivery slot + address REQUIRED), reschedule_delivery,
#           payment_setup, request_kyc
#
# THE VERBS ARE NOT HERE (T-057/K-495). They are ordinary Rails controllers under
# app/controllers/kiosk/, named in `c.handlers` below, and their writes are
# Operations under app/operations/ — which is also what lets the operator's own
# back office at GET /admin/orders read the paid state through the SAME seam the
# wire publishes it from, instead of a second copy of the same SQL. What is left
# in this file is configuration — the PoW gates, the payment provider, the
# identity providers, the KYC trust anchors — which is what an initializer is for.
#
# ADDRESS-UPFRONT (K-468): the delivery address is a deliberate, EARLY input.
# `delivery_slots` will not return slots without an in-zone Dublin address, so
# the assistant must obtain the address from its human BEFORE it can shop, and
# `create_order` re-validates the same zone rule (consistency). The operator
# validates FORMAT + ZONE only — it CANNOT verify a plausible in-zone address is
# real; the human providing/confirming the address is the ceiling (skill's job).
# Pay:      capture is wrapped by ValidatingPaymentProvider — the cart must be
#           EUR, reference the payer's unsettled order, mirror its items at
#           catalog prices, and sum correctly (the cashier check).

# Env posture (ephemeral dev signing key, PoW secret, issuer, Stripe credentials,
# test flags) lives in config/environments/{development,test,production}.rb
# (K-650/K-700); this file reads the resolved values from
# Rails.configuration.x.kiosk.* and never ENV.

require "kiosk/payment_providers/stripe"
require "kiosk/user_identity_providers/devise"

# ── Commerce catalog-toll PoW demo (KIOSK_POW_DEMO=1) ─────────────────────
#
# A grocery provider can toll the `catalog` query to price anonymous browsing
# (a metered toll, not a wall). Params follow KIOSK_POW_DIFFICULTY
# (app/services/pow_difficulty.rb): low (default) → n=96 k=5 sub-second; high → n=168 k=7
# (~10s / ~1.3 GiB). getgrocery ships low (the flagship stays poke-friendly for
# the full shop flow); the knob is here for parity. run/pay are never gated.
EQUIHASH_DEMO_PARAMS = PowDifficulty.params

# ── Registration PoW gate — ALWAYS ON — POW-VERB-GATING (K-487)
#
# register is a verb like any other: a grocery provider prices fresh-identity
# minting (one Equihash proof) so spam signups pay at the door. Independent of
# the catalog-toll gate above. Register is now uniformly tolled on every demo (no
# per-demo env flag to remember): it activates on code-deploy and can't be
# forgotten. Params follow KIOSK_POW_DIFFICULTY (getgrocery ships low → n=96 k=5
# sub-second). The gate requires the Equihash backend registered; the require +
# Backends.register run UNCONDITIONALLY here (both idempotent) so register-pow
# works regardless of KIOSK_POW_DEMO — else RegistrationPow.gate raises at register.
GETGROCERY_REGISTRATION_POW_PARAMS = PowDifficulty.params
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

if ENV["KIOSK_POW_DEMO"] == "1"
  # ⚠ TOY COUNTER — NOT a reputation signal (K-590, the atablefor K-498
  # sibling). Its ONLY job is to let the local `script/pow_flow.rb` driver
  # print "the server counted MY bad proof"; nothing reads it for policy
  # (`reputation_factors` below is `Factors.empty`). Since K-498's re-decision
  # it counts PER IDENTITY in sqlite (app/services/bad_proof_counter.rb): one abusive
  # assistant can no longer inflate anyone else's count, and concurrent server
  # processes no longer fight over one flat file. Two toy aspects REMAIN,
  # deliberately, labelled:
  #   · TRUNCATED AT BOOT — a redeploy silently zeroes the accumulated signal;
  #   · NO TTL — and never resetting is equally wrong: a count that only grows
  #     condemns an identity for something a year old.
  # A production bad-proof count keeps the per-identity keying and adds decay
  # plus durability across restarts (the same gap as the in-process revocation
  # watermark). It must be specified before it is built, not bolted on here.
  GETGROCERY_BAD_PROOF_DB = "/tmp/kiosk-getgrocery-bad-proof.sqlite3"
  BadProofCounter.reset!(GETGROCERY_BAD_PROOF_DB)

  class GetgroceryCatalogPowPolicy < Kiosk::Reputation::Policy
    def initialize(params)
      @params = params
    end

    def challenge_for(identity:, verb:, factors:)
      return nil unless verb == :query

      { alg: Kiosk::Pow::Equihash::NAME, params: @params }
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

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  # ── RLS enforce gate (demo:rls only) ─────────────────────────────────────
  # When KIOSK_RLS_ENFORCE=1, SessionContext.open appends
  #   SET LOCAL ROLE "kiosk_getgrocery_app"
  # after the GUC statements, dropping the session to the non-owner app role
  # for the duration of the transaction. That non-owner role is subject to the
  # RLS policies applied by demo:rls (ENABLE + FORCE + per-user SELECT/INSERT
  # policies on the orders table). When unset (default) there is no role-drop —
  # byte-identical to the normal shop path.
  if ENV["KIOSK_RLS_ENFORCE"] == "1"
    c.enforce_db_role = true
    c.app_role        = "kiosk_getgrocery_app"
  end

  # ── Issuer origin (K-510/K-650) ───────────────────────────────────────────
  # This operator's canonical origin — advertised in /.well-known/kiosk.json,
  # minted as the `iss` of every Kiosk JWT, and enforced as the `aud` of every
  # assistant proof-of-possession. Required in production, localhost default
  # in dev/test — the posture lives in config/environments/*.
  c.issuer = Rails.configuration.x.kiosk.issuer
  c.roles  = %i[customer]

  # ── The wire surface (T-057 / K-495 / K-761) ──────────────────────────────
  # The operator NAMES its handler controllers and the engine loads and
  # registers them on every `to_prepare` pass. Naming them is not a convenience:
  # nothing in a host app ever references a handler controller on its own — the
  # wire reaches it THROUGH the registry — so with `config.eager_load = false`
  # (development, and every generated app) an unnamed class is never autoloaded,
  # the registry stays empty, and `/.well-known/kiosk.json` advertises no
  # capabilities at all. A verb registers only when its class is named here.
  c.handlers = %w[Kiosk::StorefrontController Kiosk::OrdersController]

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
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. A
  # "beware: intensive PoW" notice appears only when KIOSK_POW_DIFFICULTY=high
  # (getgrocery ships low, so normally absent).
  c.owner  = { name: "GetGrocery", support: "demo@kiosk.tech" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.4.2.md"
  c.skill_sha256 = "f2cab5f4664ac697ce8c9a18582924447ec9097f240bac3e32ca2a8b2bf2cfed"

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
  # link-code mint and unlink. `rake demo:claim` walks the claim-rebind ceremony
  # through it, signing the shopper in at /users/sign_in first. ONE channel in
  # every environment: there is no dev-only arm to gate, because there is no
  # stub left to gate (T-066).
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new

  # Payment provider: real Stripe in test mode (sk_test_…).
  # getgrocery uses SetupIntent card-on-file: card saved once on Stripe's
  # hosted page, charged off_session per purchase.
  #
  # The principal→Stripe Customer mapping is stored in `stripe_customers` and
  # injected as lambdas — the kiosk-pay-stripe gem stays provider-agnostic.
  #
  # CREDENTIALS COME FROM THE ENVIRONMENT FILE, NOT FROM ENV (K-650/K-700).
  # config/environments/* resolves both values once, per environment: dev and
  # test hand back the mock key or a placeholder so db:setup, the schema proof,
  # isolation and redteam run with no payment config at all, and production hands
  # back exactly what was supplied and invents nothing. So there is no
  # `Rails.env` branch left in this file — the posture is the environment's to
  # state, and what is left here is this app's own reaction to it.
  #
  # Real Stripe by default (demo:shop → real pi_…). When a mock base URL is
  # configured (the adversarial suites, and CI, which carries no key), point the
  # SDK at a local stripe-mock instead — fast, no key, no real charges.
  # stripe-mock returns shaped fixtures, so the full pay→settlement flow runs and
  # the Kiosk gates (ownership + "settlement exists") are exercised end-to-end
  # without hitting Stripe. `Stripe.api_base` is the one thing that could NOT
  # move to the environment file: that file is byte-identical across the seven
  # operator demos and the SDK constant does not exist in the six that bundle no
  # payment adapter.
  key = Rails.configuration.x.kiosk.stripe_secret_key
  if (mock = Rails.configuration.x.kiosk.stripe_mock_url).present?
    require "stripe"
    Stripe.api_base = mock                          # e.g. http://127.0.0.1:12111
  end
  # Dev and test resolve a key unconditionally, so a blank one here means
  # production was started without a payment credential — and an origin that
  # ADVERTISES `pay` in its discovery document and then cannot charge is worse
  # than one that refuses to boot.
  raise "getgrocery requires STRIPE_SECRET_KEY (sk_test_…) or STRIPE_MOCK_URL" if key.blank?

  # test_autocard (set by the demo/redteam/isolation rake tasks via
  # KIOSK_TEST_AUTOCARD=1) makes the adapter simulate a completed SetupIntent —
  # automated suites need no card-setup step and no server-side test route.
  # config/environments/production.rb pins it FALSE (K-650), so the live demo
  # always runs the real hosted SetupIntent flow (human enters the card once).
  # The cashier check: ValidatingPaymentProvider verifies the agent-signed
  # cart against OUR catalog — currency (EUR), per-line prices, and total —
  # before the wrapped Stripe adapter captures anything.
  c.payment_provider = ValidatingPaymentProvider.new(
    Kiosk::PaymentProviders::Stripe.new(
      api_key:           key,
      customer_resolver: ->(uid) { StripeCustomer.find_by(user_id: uid)&.customer_id },
      customer_saver:    ->(uid, cid) { StripeCustomer.create!(user_id: uid, customer_id: cid) },
      test_autocard:     Rails.configuration.x.kiosk.test_autocard,
      return_url:        "#{Kiosk.configuration.issuer}/payment/return",
    ),
    currency: "eur",
  )

  # ── KYC attestation verifier — trusts the KYC broker ────────────────
  # The alcohol age-gate (create_order rejecting a cart with an age_restricted
  # item unless the agent carries age_over_18) reads the engine-verified
  # kyc_attributes. getgrocery does NOT host its own issuer: it configures the
  # SHARED KYC broker as its kyc_issuer + kyc_public_key ONCE and asks the
  # broker for exactly the ONE claim it needs (age_over_18 — NOT a driving
  # licence). The issuer identity comes from ProveTrust; the broker PUBLIC KEY
  # comes from Rails.configuration.x.kiosk (config/environments — K-650): the
  # harness/deploy pins it explicitly, there is NO shipped fallback key, and
  # with none set the engine's KycVerifier fails closed at the wire. Same two
  # config attributes the shipped KycVerifier already reads.
  c.kyc_issuer     = ProveTrust.issuer
  c.kyc_public_key = Rails.configuration.x.kiosk.prove_public_key_pem
  # OPERATOR-BINDING (aud): the engine KycVerifier REJECTS at the wire any
  # attestation whose `aud` != this operator's kyc_audience — so a claim the
  # broker minted for skooti cannot unlock getgrocery even before getgrocery's
  # callback-layer operator check runs. getgrocery declares its stable broker
  # handle ("getgrocery") as the audience, not its per-deploy origin URL.
  c.kyc_audience   = ProveTrust.operator_id

  # ── Catalog-toll PoW gate (active only when KIOSK_POW_DEMO=1) ────────────
  if ENV["KIOSK_POW_DEMO"] == "1"
    c.reputation_policy  = GetgroceryCatalogPowPolicy.new(Kiosk::Pow::Equihash.params(**EQUIHASH_DEMO_PARAMS))
    c.pow_ttl            = 300
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }
    # ⚠ TOY COUNTER — the write side of the demo counter defined above; the
    # two remaining caveats there apply verbatim (boot-truncated, no TTL —
    # K-590/K-498). PER IDENTITY since K-498's re-decision: keyed by the
    # verified agent credential id the gate hands in, so one abuser's
    # rejections never appear in anyone else's count. Its only consumer is the
    # local driver script/pow_flow.rb; `reputation_factors` right above feeds
    # the policy `Factors.empty`, so nothing this counts changes any toll.
    c.on_bad_proof = ->(identity:) {
      BadProofCounter.increment(GETGROCERY_BAD_PROOF_DB, identity.agent_id)
    }
  end

  # ── Registration PoW gate — ALWAYS ON (register is uniformly tolled) ──────
  # Price fresh-identity minting: registering an agent costs ONE Equihash proof.
  # Independent of the catalog toll above; pow_secret is set unconditionally so the
  # gate works even when KIOSK_POW_DEMO is off (RegistrationPow.gate raises without
  # it) — the catalog-toll branch above shares this one assignment.
  c.registration_pow_count  = 1
  c.registration_pow_params = GETGROCERY_REGISTRATION_POW_PARAMS
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
# Off unless KIOSK_TELEMETRY=1. When on, one event is recorded per successful
# wire action via a Rack middleware; the aggregate is served at
# GET /demo/activity.json. NOT part of kiosk-core (satellite neutrality).
# GETGROCERY_VERB_MAP maps this vertical's concrete run-verbs onto the generic
# action kinds so the landing aggregate reads uniformly across demos.
if ENV["KIOSK_TELEMETRY"] == "1"
  GETGROCERY_VERB_MAP = {
    "create_order"        => "ordered",
    "reschedule_delivery" => "scheduled",
    "payment_setup"       => "ran",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: GETGROCERY_VERB_MAP,
  )
end
