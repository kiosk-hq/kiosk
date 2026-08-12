# frozen_string_literal: true

# Kiosk-demo (getgrocery-shape) configuration.
# Single grocery provider — no store layer. Catalog exposes in-stock facts;
# the AI assistant handles substitution decisions.
# Queries:  catalog, delivery_slots (delivery ADDRESS/zone REQUIRED — validated
#           against served Dublin districts), my_orders
# Actions:  create_order (delivery slot + address REQUIRED), reschedule_delivery, payment_setup
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

# Env posture (ephemeral dev signing key, PoW secret, issuer, test flags) lives
# in config/environments/{development,test,production}.rb (K-650); this file
# reads the resolved values from Rails.configuration.x.kiosk.*.

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/stub_user_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/pow_difficulty")
require Rails.root.join("lib/dublin_zones")
require Rails.root.join("lib/delivery_slots")
require Rails.root.join("lib/uuid_check")
require Rails.root.join("lib/bad_proof_counter")
require Rails.root.join("lib/validating_payment_provider")
require Rails.root.join("lib/prove_trust")
require Rails.root.join("lib/prove_broker_client")
require "kiosk/payment_providers/stripe"

ActiveRecord::Migration.include(Kiosk::RLS::DSL)

# ── Commerce catalog-toll PoW demo (KIOSK_POW_DEMO=1) ─────────────────────
#
# A grocery provider can toll the `catalog` query to price anonymous browsing
# (a metered toll, not a wall). Params follow KIOSK_POW_DIFFICULTY
# (lib/pow_difficulty.rb): low (default) → n=96 k=5 sub-second; high → n=168 k=7
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
  # it counts PER IDENTITY in sqlite (lib/bad_proof_counter.rb): one abusive
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

  # UNIFORM-VALIDATION slice-1 (K-479): validate a PRESENT `pow` field against
  # the normative PoW schema at the wire choke point, so a malformed pow gets a
  # clear 400 bad_request (with a shape hint) instead of a silent re-issued 402
  # loop. Needs the json_schemer gem (in the Gemfile). Absent/valid pow paths
  # unchanged.
  c.validate_requests = true
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
  c.skill_url    = "https://kiosk.tech/skill-v0.3.10.md"
  c.skill_sha256 = "67265bd147ea3c6c32b240b1f2fc17f57ba17342770b989270ce34eb3f302a91"

  c.agent_idp = JwtOrStubIdp.new(stub: Rails.env.local? ? StubIdp.new : nil)
  # The provider's own web-session channel: authenticates the approving
  # human on the account-binding surfaces (device verify page, link mint,
  # unlink). A stub because this demo has no human login UI — see
  # lib/stub_user_idp.rb for the honest scope; `rake demo:claim` walks
  # the claim-rebind ceremony through it.
  # DEV/TEST ONLY (K-555): the stub parses an UNSIGNED, self-asserted
  # `user:u-<uuid>` bearer into a human identity, so it is wired only under
  # Rails.env.local?; in production user_idp is nil and the binding surfaces
  # 401 until a real adapter (kiosk-user-idp-devise) is configured.
  c.user_idp = Rails.env.local? ? StubUserIdp.new : nil

  # Payment provider: real Stripe in test mode (sk_test_…).
  # getgrocery uses SetupIntent card-on-file: card saved once on Stripe's
  # hosted page, charged off_session per purchase.
  #
  # The principal→Stripe Customer mapping is stored in `stripe_customers` and
  # injected as lambdas — the kiosk-pay-stripe gem stays provider-agnostic.
  #
  # Real Stripe by default (demo:shop → real pi_…). When STRIPE_MOCK_URL is set
  # (the adversarial suites), point the SDK at a local stripe-mock instead —
  # fast, no key, no real charges. stripe-mock returns shaped fixtures, so the
  # full pay→settlement flow runs and the Kiosk gates (ownership + "settlement
  # exists") are exercised end-to-end without hitting Stripe.
  if (mock = ENV["STRIPE_MOCK_URL"]) && !mock.empty?
    require "stripe"
    Stripe.api_base = mock                          # e.g. http://127.0.0.1:12111
    key = ENV["STRIPE_SECRET_KEY"].to_s.empty? ? "sk_test_mock" : ENV["STRIPE_SECRET_KEY"]
  else
    key = ENV["STRIPE_SECRET_KEY"]
    if key.nil? || key.empty?
      # Out-of-box parity with the sibling demos: in dev/test the
      # app boots on a placeholder so db:setup/schema/isolation/redteam run with
      # no payment config; only a REAL charge (demo:shop) needs a live key or
      # STRIPE_MOCK_URL, and fails clearly at charge time if neither is set.
      raise "getgrocery requires STRIPE_SECRET_KEY (sk_test_…) or STRIPE_MOCK_URL" unless Rails.env.local?
      warn "[getgrocery] no STRIPE_SECRET_KEY/STRIPE_MOCK_URL set — using a placeholder key; demo:shop needs one to charge."
      key = "sk_test_placeholder"
    end
  end

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
end

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. When on, one event is recorded per successful
# wire action via a Rack middleware; the aggregate is served at
# GET /demo/activity.json. NOT part of kiosk-core (satellite neutrality).
# GETGROCERY_VERB_MAP maps this vertical's concrete run-verbs onto the generic
# action kinds so the landing aggregate reads uniformly across demos.
if ENV["KIOSK_TELEMETRY"] == "1"
  require Rails.root.join("lib/demo_telemetry")
  GETGROCERY_VERB_MAP = {
    "create_order"        => "ordered",
    "reschedule_delivery" => "scheduled",
    "payment_setup"       => "ran",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: GETGROCERY_VERB_MAP,
  )
end

LOW_STOCK_THRESHOLD = 5

# ─── Queries ────────────────────────────────────────────────────────────────

Kiosk::Server::Queries.register("catalog",
  description: "Browse in-stock products from the getgrocery catalog (out-of-stock items are hidden). " \
               "All prices are EUR cents — carts must be signed in eur at these exact prices. " \
               "Takes no parameters and returns the whole in-stock catalogue (small; not paginated); " \
               "each row carries the stable `sku` (reference products by sku, never the numeric id), a " \
               "`low` flag when stock is running out, and an `age_restricted` flag on alcohol — an " \
               "age_restricted item can only be ORDERED (create_order) by an agent that has completed an " \
               "18+ anonymized-KYC check (run request_kyc first); non-restricted items need no KYC.",
  params: {},
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {},
    required: [],
  },
  example_params: {},
  example_row: {
    sku: "sourdough-bread", name: "Sourdough Bread", price_cents: 449,
    price_eur: "€4.49", currency: "eur",
  }) do |_params|
  conn = ActiveRecord::Base.connection
  rows = conn.execute(
    "SELECT sku, name, price_cents, stock, age_restricted FROM products WHERE stock > 0 ORDER BY name"
  ).to_a
  rows.map do |r|
    row = { "sku" => r["sku"], "name" => r["name"], "price_cents" => r["price_cents"],
            "price_eur" => Product.format_eur(r["price_cents"]), "currency" => "eur" }
    row["low"] = true if r["stock"].to_i <= LOW_STOCK_THRESHOLD
    # Advertise the 18+ gate on alcohol so an assistant knows to complete
    # anonymized KYC (request_kyc) BEFORE it tries to order this item.
    row["age_restricted"] = true if r["age_restricted"] == true || r["age_restricted"] == "t"
    row
  end
end

Kiosk::Server::Queries.register("delivery_slots",
  description: "Get available delivery time slots for a date at a Dublin delivery address. " \
               "delivery_address is REQUIRED and must be an in-zone Dublin address (a postal " \
               "district — e.g. \"42 Camden Street, Dublin 2\" or an Eircode like \"D02 XY45\"). " \
               "getgrocery routes by district and delivers only within its served Dublin zones; " \
               "an out-of-zone or district-less address returns 400 (bad_request) naming what is " \
               "needed. Obtain the real address from your human FIRST — the same address is required " \
               "again at create_order. NOTE: the operator validates format + zone only; it cannot " \
               "verify a plausible in-zone address is real, so confirm it with your human. " \
               "Each row carries a `delivery_slot_id` (and its `date`); pass both to create_order " \
               "as `delivery_slot_id` and `delivery_date`.",
  params: {
    date:             "date string YYYY-MM-DD — desired delivery date",
    delivery_address: "string — the Dublin delivery address (must name a served postal district), REQUIRED",
  },
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      date:             { type: "string", description: "Delivery date, YYYY-MM-DD." },
      delivery_address: { type: "string", description: "Dublin delivery address naming a served postal district." },
    },
    required: ["date", "delivery_address"],
  },
  example_params: { date: "2026-08-10", delivery_address: "42 Camden Street, Dublin 2" },
  example_row: { delivery_slot_id: 1, date: "2026-08-10", slot_at: "2026-08-10T08:00:00+01:00", label: "08:00–10:00", zone: "D02" }) do |params|
  date = params.fetch(:date) { raise Kiosk::Server::Errors::BadRequest.new("missing param: date") }

  # ADDRESS-UPFRONT (K-468): the delivery address is a REQUIRED early input.
  # Validate it names a SERVED Dublin district — reject out-of-zone/malformed
  # with a clean 400 (bad_request), never a 500. This forces the assistant to
  # obtain the address from its human before it can even see slots. The check is
  # FORMAT + ZONE only: it cannot prove a plausible in-zone address is real.
  delivery_address = params[:delivery_address]
  if delivery_address.blank?
    raise Kiosk::Server::Errors::BadRequest.new(
      DublinZones.reject_message(DublinZones::Result.new(ok: false, zone: nil, reason: :blank)),
    )
  end
  zone_result = DublinZones.check(delivery_address)
  unless zone_result.ok?
    raise Kiosk::Server::Errors::BadRequest.new(DublinZones.reject_message(zone_result))
  end
  served_zone = zone_result.zone

  parsed = begin
    Date.parse(date.to_s)
  rescue ArgumentError
    raise Kiosk::Server::Errors::BadRequest.new("invalid date: #{date}")
  end

  # PAST-SLOT FILTER (K-480): return ONLY still-bookable windows. For TODAY, drop
  # any slot whose start has already passed in the operator's locale (Dublin);
  # future dates keep all slots. If every one of today's slots has begun,
  # delivery_slots for today is legitimately empty and the earliest bookable slot
  # is on a later date — the assistant simply shouldn't see an un-bookable
  # 08:00–10:00 window at 11:00. `date` on each row (K-470) is unchanged so
  # create_order books exactly the day/slot shown.
  DeliverySlots.bookable_ids(parsed).map do |slot_id|
    slot_time = DeliverySlots.slot_at(parsed, slot_id)
    hour      = slot_time.hour
    {
      "delivery_slot_id" => slot_id,
      "date"    => parsed.iso8601,
      "slot_at" => slot_time.iso8601,
      "label"   => "#{hour.to_s.rjust(2, "0")}:00–#{(hour + DeliverySlots::WINDOW_HOURS).to_s.rjust(2, "0")}:00",
      "zone"    => served_zone,
    }
  end
end

Kiosk::Server::Queries.register("my_orders",
  description: "List this principal's orders with delivery slot, address, and a paid flag (scoped to authenticated user via kiosk.current_user_id()). Each row carries an `order_id`; pass it to reschedule_delivery (or create_order to replace an unpaid order) as `order_id`. Use the `paid` flag as a settlement lookup: after a pay whose response you did not receive, re-read my_orders and only retry pay if the order is still unpaid (K-545).") do |_params|
  # K-545: `paid` is true when a settlement exists OR the order reached the
  # terminal `paid` state at capture. The order flips to `paid` the instant the
  # charge succeeds — a hair before the engine writes the settlement row — so
  # honouring the status closes the window where a lost pay response would
  # otherwise read paid=false and tempt a double-charging retry.
  ActiveRecord::Base.connection.execute(
    "SELECT o.id AS order_id, o.status, o.total_cents, o.slot_at, o.address, " \
    "(o.status = 'paid' OR EXISTS (" \
    "SELECT 1 FROM kiosk.settlements pm " \
    "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
    "WHERE pm.user_id = kiosk.current_user_id() " \
    "AND cm.line_items @> json_build_array(json_build_object('order_id', o.id::text))::jsonb" \
    ")) AS paid " \
    "FROM orders o " \
    "WHERE o.user_id = kiosk.current_user_id() " \
    "ORDER BY o.created_at DESC"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

# payment_setup — the card-on-file readiness probe.
#
# POLL CADENCE + STOP CONDITION (K-477): the wire has no server→assistant push,
# so an assistant learns the human finished the hosted card entry ONLY by
# re-calling this. The descriptor therefore has to state a cadence AND a
# terminal stop condition — without one an agent invents its own and can poll
# forever if the human never completes the step.
#
# The cadence here is the skill's, verbatim (skill.md Step 5: ~5 s for the first
# minute, then ~15 s, give up after ~5 minutes) — the skill is what assistants
# actually follow, so a descriptor that prescribes anything else is a second,
# losing instruction. And no CHECK COUNT is stated: a count is derived from the
# cadence and the horizon, so it silently goes wrong the moment either moves
# (the earlier "~60 checks" implied a flat 5 s cadence and was more than double
# what this schedule yields). The horizon is the number an assistant needs.
#
# SAFE TO RE-CALL (K-492): the probe is idempotent. When setup is required the
# Stripe adapter reuses the setup session already outstanding for this
# principal instead of minting a new one, so every poll returns the SAME
# setup_url — an assistant relaying the newest url can no longer bounce its
# human off the page they are filling in.
Kiosk::Server::Actions.register("payment_setup",
  description: "Check whether the authenticated principal has a saved card on file. " \
               "Returns {status: \"ready\"} if a card is already saved and the assistant can proceed to `pay`. " \
               "Returns {status: \"setup_required\", setup_url: \"…\"} when no card is saved — " \
               "the assistant must hand the setup_url to the human, wait for them to complete the " \
               "Stripe-hosted card entry, then call payment_setup again before paying. " \
               "The assistant should call this before every `pay` invocation on a new device or session. " \
               "POLLING: while your human is at the hosted page, re-check every ~5 seconds for the first " \
               "minute, then every ~15 seconds, and GIVE UP after about 5 minutes — tell your human the " \
               "card setup is still not finished rather than polling indefinitely; they can finish later " \
               "and you re-check then. " \
               "Re-checking is safe and repeatable: while one setup is outstanding this normally returns " \
               "the SAME setup_url, so relay that one link and do NOT send your human a new one per check " \
               "— and if a check ever does come back with a different url, still leave your human on the " \
               "page they already have open unless they tell you it stopped working.",
  params: {}) do |_args|
  conn     = ActiveRecord::Base.connection
  uid      = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  provider = Kiosk.configuration.payment_provider
  issuer   = Kiosk.configuration.issuer

  # Key off setup_required? (not saved_method?) so it honours the adapter's
  # policy — incl. KIOSK_TEST_AUTOCARD, where setup is auto-completed at capture
  # and this returns "ready" without a hosted-page round-trip.
  if provider.setup_required?(user_id: uid)
    { status: "setup_required", setup_url: provider.setup_url(user_id: uid) }
  else
    { status: "ready" }
  end
end

Kiosk::Server::Actions.register("create_order",
  description: "Create (or replace) a grocery order for the authenticated principal. " \
               "Delivery is part of the order: delivery_slot_id and delivery_address are REQUIRED. " \
               "To pay, sign your AP2 cart mandate in EUR with line_items that mirror the order — " \
               "one {\"order_id\": <the returned order_id>} entry plus one {\"sku\", \"qty\", \"price_cents\"} " \
               "entry per item at catalog prices; the operator verifies currency, prices, and total " \
               "against its catalog before charging (the result carries a pay_hint)",
  params: {
    items:            "array of {sku, qty} — the complete cart (products referenced by sku)",
    delivery_slot_id: "integer — the `delivery_slot_id` from a delivery_slots row (1–6), REQUIRED",
    delivery_date:    "date string YYYY-MM-DD — the DATE of the slot you chose (copy the `date` from that " \
                      "delivery_slots row) so the booking is on the day you saw. Omitting it books tomorrow.",
    delivery_address: "string — in-zone Dublin delivery address (must name a served postal district, " \
                      "the SAME zone you queried delivery_slots with), REQUIRED. An out-of-zone or " \
                      "district-less address returns 400. Get it from your human — it cannot be verified as real.",
    order_id:         "(optional) uuid — if given and order belongs to principal and not yet paid, replaces its items and delivery details",
  },
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      items: {
        type: "array", minItems: 1,
        description: "The complete cart — products referenced by sku.",
        items: {
          type: "object", additionalProperties: false,
          properties: {
            sku: { type: "string", description: "Product sku from the catalog query." },
            qty: { type: "integer", minimum: 1, description: "Quantity." },
          },
          required: ["sku", "qty"],
        },
      },
      delivery_slot_id: { type: "integer", minimum: 1, maximum: 6,
                          description: "The `delivery_slot_id` from a delivery_slots row (1..6)." },
      delivery_date:    { type: "string",
                          description: "The `date` (YYYY-MM-DD) of the chosen delivery_slots row, so the booking lands on the day you saw. Optional; omitting books tomorrow." },
      delivery_address: { type: "string",
                          description: "In-zone Dublin delivery address naming a served postal district (e.g. \"Dublin 2\" / \"D02\")." },
      # K-596: `pattern`/`format` so the DECLARED contract carries the shape the
      # description asserts and the handler enforces (UuidCheck) — a bare
      # {type:"string"} told an assistant nothing about what "uuid" meant here.
      order_id:         { type: "string", format: "uuid",
                          pattern: UuidCheck::JSON_SCHEMA_PATTERN,
                          description: "Optional uuid of an unpaid order to replace." },
    },
    required: ["items", "delivery_slot_id", "delivery_address"],
  },
  example_params: {
    items: [{ sku: "sourdough-bread", qty: 2 }, { sku: "greek-yogurt", qty: 1 }],
    delivery_slot_id: 3, delivery_date: "2026-08-10", delivery_address: "42 Camden Street, Dublin 2",
  },
  example_row: {
    order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e", total_cents: 1287,
    total_eur: "€12.87", currency: "eur", slot_at: "2026-08-10T12:00:00+01:00",
    pay_hint: "pay in EUR with a cart mandate whose line_items mirror this order …",
  }) do |args|
  conn = ActiveRecord::Base.connection
  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  items = args[:items] || []
  raise Kiosk::Server::Errors::BadRequest.new("items must be a non-empty array") if items.empty?

  items = items.map do |it|
    sku = it[:sku].to_s
    qty = (it[:qty] || 1).to_i
    raise Kiosk::Server::Errors::BadRequest.new("each item needs a sku") if sku.empty?
    raise Kiosk::Server::Errors::BadRequest.new("qty must be >= 1") if qty < 1
    { sku: sku, qty: qty }
  end

  delivery_slot_id = args[:delivery_slot_id]
  delivery_address = args[:delivery_address]
  raise Kiosk::Server::Errors::BadRequest.new("missing field: delivery_slot_id — delivery is part of the order") if delivery_slot_id.nil?
  raise Kiosk::Server::Errors::BadRequest.new("missing field: delivery_address — delivery is part of the order") if delivery_address.blank?
  # ADDRESS-UPFRONT (K-468): re-validate the delivery address against the SAME
  # served-Dublin-zone rule the slots were issued under (consistency) — an
  # out-of-zone / district-less address that slipped past (or a different one
  # than was used for delivery_slots) is rejected here with a clean 400, never a
  # 500. Format + zone only: the operator still cannot verify a plausible
  # in-zone address is real — the human must confirm it (skill's job).
  zone_result = DublinZones.check(delivery_address)
  raise Kiosk::Server::Errors::BadRequest.new(DublinZones.reject_message(zone_result)) unless zone_result.ok?
  slot_id = delivery_slot_id.to_i
  raise Kiosk::Server::Errors::BadRequest.new("delivery_slot_id must be 1–#{DeliverySlots::COUNT}") unless (1..DeliverySlots::COUNT).include?(slot_id)

  # K-470: honor the DATE of the slot the agent chose in delivery_slots — the
  # day+time create_order books MUST equal the day+time the assistant saw. The
  # agent passes back the delivery_date it queried delivery_slots with (returned
  # on each slot row as `date`); compute slot_at from that same (date, slot_id)
  # via the shared DeliverySlots helper. A past date is rejected (a clean 400).
  # Backward-compat: if delivery_date is omitted, fall back to tomorrow (the
  # historical default) so callers that pre-date this field still work — but a
  # caller that saw a slot for a specific day SHOULD pass that day back.
  raw_date = args[:delivery_date]
  delivery_date =
    if raw_date.blank?
      Date.today + 1
    else
      begin
        Date.parse(raw_date.to_s)
      rescue ArgumentError
        raise Kiosk::Server::Errors::BadRequest.new("invalid delivery_date: #{raw_date} — use YYYY-MM-DD from the delivery_slots row you chose")
      end
    end
  raise Kiosk::Server::Errors::BadRequest.new("delivery_date is in the past: #{delivery_date} — choose a current/future delivery slot") if delivery_date < Date.today
  slot_at = DeliverySlots.slot_at(delivery_date, slot_id)
  # PAST-SLOT RE-VALIDATION (K-480): mirror the delivery_slots filter so
  # create_order can't book a window delivery_slots would now hide as past — a
  # TODAY slot whose start has already passed in the operator's locale (Dublin)
  # is rejected with a clean 400 (whole past DAYS were already caught above; this
  # catches a past TIME-OF-DAY today, e.g. booking the 08:00 slot at 11:00).
  if DeliverySlots.past?(delivery_date, slot_id)
    raise Kiosk::Server::Errors::BadRequest.new(
      "delivery slot #{slot_id} on #{delivery_date} has already started (#{slot_at.iso8601}) — " \
      "choose a later slot; call delivery_slots again for the still-bookable windows"
    )
  end

  conn.transaction do
    # Resolve skus → product id + price (consumer references products by sku, not the numeric id)
    quoted_skus = items.map { |i| conn.quote(i[:sku]) }.uniq.join(", ")
    product_rows = conn.execute(
      "SELECT id, sku, price_cents, age_restricted FROM products WHERE sku IN (#{quoted_skus})"
    ).to_a
    by_sku = product_rows.each_with_object({}) { |r, h| h[r["sku"]] = r }

    missing = items.map { |i| i[:sku] }.uniq.reject { |s| by_sku.key?(s) }
    raise Kiosk::Server::Errors::BadRequest.new("unknown sku(s): #{missing.join(", ")}") unless missing.empty?

    # ── Age gate: any age_restricted item in the cart requires age_over_18 ────
    # KYC-DEMO-SCOPE (b): anonymized minimal KYC belongs on a LOW-liability
    # eligibility gate where the transaction closes (an alcohol PURCHASE), not on
    # high-liability rental. If the cart contains ANY age_restricted product, the
    # authenticated agent must carry an engine-verified age_over_18 attestation.
    # Only booleans a valid, broker-signed attestation granted are ever persisted
    # in kiosk_attributes — a forged/self-asserted claim never reaches this column
    # (POST /kiosk/agents/kyc rejects a bad signature). A cart with no restricted
    # item skips this entirely (unchanged path). Read the flag as boolean-safe.
    has_restricted = items.any? do |i|
      v = by_sku[i[:sku]]["age_restricted"]
      v == true || v == "t" || v == "true"
    end
    if has_restricted
      kyc_row = conn.execute(<<~SQL).first
        SELECT COALESCE(kyc_attributes ->> 'age_over_18', 'false') AS age_over_18
        FROM kiosk.agents
        WHERE id = kiosk.current_agent_id()
          AND revoked_at IS NULL
      SQL
      unless kyc_row && kyc_row["age_over_18"] == "true"
        raise Kiosk::Server::Errors::KycRequired.new(
          "this cart contains an age-restricted (alcohol) item — an 18+ verification is required to order it",
          # Point an external agent at the completable path: `run request_kyc`
          # returns a verification_url the human approves, then poll `query
          # kyc_status` for the signed attestation and submit it to POST
          # /kiosk/agents/kyc — no pre-shared issuer key needed.
          hint: "call `run request_kyc` to start an 18+ (age_over_18) verification: " \
                "it returns a verification_url for the human to approve; then poll " \
                "`query kyc_status` for the signed attestation and submit it to " \
                "POST /kiosk/agents/kyc, then retry create_order",
        )
      end
    end

    total_cents = items.sum { |i| by_sku[i[:sku]]["price_cents"].to_i * i[:qty] }

    # Optional order_id: replace items if order belongs to principal and is not yet paid/scheduled
    given_order_id = args[:order_id]
    order_id = nil

    if given_order_id.present?
      # K-579: this id is cast `::uuid` below — a malformed one made Postgres
      # raise InvalidTextRepresentation, surfacing as a raw 500 for what is
      # plainly a client mistake. Check the shape first, answer 400.
      unless UuidCheck.valid?(given_order_id)
        raise Kiosk::Server::Errors::BadRequest.new(
          "order_id #{given_order_id.to_s.inspect} is not a uuid — pass the `order_id` a previous " \
          "create_order returned (or omit it to place a new order)"
        )
      end
      settled_filter = [{ order_id: given_order_id.to_s }].to_json
      # K-544: exclude `paying` (a /pay for this order is mid-flight — its items
      # MUST NOT be swapped from under it) as well as the terminal states, and
      # take a row lock (FOR UPDATE) so this replace serializes against the
      # pay-path's atomic claim. Together they make "replace items" and "begin
      # paying" mutually exclusive on the order row.
      existing = conn.execute(
        "SELECT o.id FROM orders o " \
        "WHERE o.id = #{conn.quote(given_order_id.to_s)}::uuid " \
        "AND o.user_id = #{conn.quote(uid)}::uuid " \
        "AND o.status NOT IN ('paid', 'paying', 'scheduled', 'rescheduled') " \
        "AND NOT EXISTS (" \
        "SELECT 1 FROM kiosk.settlements pm " \
        "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
        "WHERE cm.line_items @> #{conn.quote(settled_filter)}::jsonb" \
        ") " \
        "LIMIT 1 FOR UPDATE"
      ).first

      if existing
        order_id = existing["id"]
        # Replace items
        conn.execute("DELETE FROM order_items WHERE order_id = #{conn.quote(order_id.to_s)}::uuid")
        conn.execute(
          "UPDATE orders SET total_cents = #{conn.quote(total_cents)}, " \
          "slot_at = #{conn.quote(slot_at.iso8601)}::timestamptz, " \
          "address = #{conn.quote(delivery_address.to_s)}, updated_at = now() " \
          "WHERE id = #{conn.quote(order_id.to_s)}::uuid"
        )
      end
    end

    unless order_id
      # Create new order
      order_id = conn.execute(
        "INSERT INTO orders (id, user_id, status, total_cents, slot_at, address, created_at, updated_at) " \
        "VALUES (gen_random_uuid(), #{conn.quote(uid)}::uuid, 'created', #{conn.quote(total_cents)}, " \
        "#{conn.quote(slot_at.iso8601)}::timestamptz, #{conn.quote(delivery_address.to_s)}, now(), now()) " \
        "RETURNING id"
      ).first["id"]
    end

    # Insert order_items (resolve each sku → internal product id)
    items.each do |item|
      product_id = by_sku[item[:sku]]["id"]
      conn.execute(
        "INSERT INTO order_items (order_id, product_id, qty, created_at, updated_at) " \
        "VALUES (#{conn.quote(order_id.to_s)}::uuid, #{conn.quote(product_id.to_s)}::integer, " \
        "#{conn.quote(item[:qty].to_s)}::integer, now(), now())"
      )
    end

    {
      order_id:    order_id,
      total_cents: total_cents,
      total_eur:   Product.format_eur(total_cents),
      currency:    "eur",
      slot_at:     slot_at.iso8601,
      pay_hint:    "pay in EUR with a cart mandate whose line_items mirror this order: " \
                   "one {\"order_id\": \"#{order_id}\"} entry plus one " \
                   "{\"sku\", \"qty\", \"price_cents\"} entry per item at catalog prices — " \
                   "the operator verifies currency, prices, and total before charging",
    }
  end
end

Kiosk::Server::Actions.register("reschedule_delivery",
  description: "Move an ALREADY-PAID order's delivery to a different slot (and optionally a new address). " \
               "This REUSES the order's existing payment — do NOT pay again. Just call " \
               "reschedule_delivery(order_id, delivery_slot_id[, delivery_date[, delivery_address]]) directly; " \
               "there is no new mandate/settlement to sign. The precondition \"the order must already be paid\" " \
               "means a settlement for it ALREADY EXISTS (from when you first paid) — it does NOT mean settle " \
               "now, and re-paying a paid order is rejected (403 order already settled). " \
               "One reschedule per order — further changes go through the operator. " \
               "Unpaid orders can't be rescheduled: re-place them instead via create_order with order_id.",
  params: {
    order_id:         "uuid — the ALREADY-PAID order to reschedule (its existing payment is reused; do not pay again)",
    delivery_slot_id: "integer — the new `delivery_slot_id` from a delivery_slots row (1–6)",
    delivery_date:    "(optional) date string YYYY-MM-DD — the `date` of the new slot you chose; omitting books tomorrow",
    delivery_address: "(optional) string — new delivery address; unchanged if omitted",
  },
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      # K-596: same uuid shape as create_order's order_id — see UuidCheck.
      order_id:         { type: "string", format: "uuid",
                          pattern: UuidCheck::JSON_SCHEMA_PATTERN,
                          description: "uuid of the ALREADY-PAID order to reschedule. Its existing payment is reused — do not pay again." },
      delivery_slot_id: { type: "integer", minimum: 1, maximum: 6,
                          description: "The new `delivery_slot_id` from a delivery_slots row (1..6)." },
      delivery_date:    { type: "string",
                          description: "The `date` (YYYY-MM-DD) of the chosen delivery_slots row. Optional; omitting books tomorrow." },
      delivery_address: { type: "string",
                          description: "Optional new in-zone Dublin delivery address; unchanged if omitted." },
    },
    required: ["order_id", "delivery_slot_id"],
  },
  example_params: { order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e", delivery_slot_id: 3, delivery_date: "2026-08-10" },
  example_row: { order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e", rescheduled_at: "2026-08-10T12:00:00+01:00" }) do |args|
  conn = ActiveRecord::Base.connection

  order_id         = args[:order_id]
  delivery_slot_id = args[:delivery_slot_id]
  delivery_address = args[:delivery_address]

  raise Kiosk::Server::Errors::BadRequest.new("missing field: order_id")         if order_id.blank?
  raise Kiosk::Server::Errors::BadRequest.new("missing field: delivery_slot_id") if delivery_slot_id.nil?
  # K-579: cast `::uuid` below — reject a malformed id as a clean 400, not a 500.
  unless UuidCheck.valid?(order_id)
    raise Kiosk::Server::Errors::BadRequest.new(
      "order_id #{order_id.to_s.inspect} is not a uuid — pass the `order_id` from my_orders or create_order"
    )
  end

  # ADDRESS-UPFRONT (K-468): if a NEW address is supplied, it must also be an
  # in-zone Dublin address — clean 400, not a 500. Omitted → keep the existing.
  if delivery_address.present?
    zone_result = DublinZones.check(delivery_address)
    raise Kiosk::Server::Errors::BadRequest.new(DublinZones.reject_message(zone_result)) unless zone_result.ok?
  end

  slot_id = delivery_slot_id.to_i
  raise Kiosk::Server::Errors::BadRequest.new("delivery_slot_id must be 1–#{DeliverySlots::COUNT}") unless (1..DeliverySlots::COUNT).include?(slot_id)

  # K-470: honor the chosen slot's DATE (same source of truth as delivery_slots /
  # create_order). Optional for backward compat → tomorrow. Reject a past date.
  raw_date = args[:delivery_date]
  new_date =
    if raw_date.blank?
      Date.today + 1
    else
      begin
        Date.parse(raw_date.to_s)
      rescue ArgumentError
        raise Kiosk::Server::Errors::BadRequest.new("invalid delivery_date: #{raw_date} — use YYYY-MM-DD from the delivery_slots row you chose")
      end
    end
  raise Kiosk::Server::Errors::BadRequest.new("delivery_date is in the past: #{new_date}") if new_date < Date.today
  # PAST-SLOT RE-VALIDATION (K-480): same rule as create_order — a TODAY slot
  # whose start has already passed in the operator's locale (Dublin) is rejected
  # (a clean 400), so a reschedule can't land on an un-bookable past window.
  if DeliverySlots.past?(new_date, slot_id)
    raise Kiosk::Server::Errors::BadRequest.new(
      "delivery slot #{slot_id} on #{new_date} has already started " \
      "(#{DeliverySlots.slot_at(new_date, slot_id).iso8601}) — choose a later slot; " \
      "call delivery_slots again for the still-bookable windows"
    )
  end

  conn.transaction do
    # ── Gate 1: order belongs to principal and not already scheduled ─────
    order = conn.execute(
      "SELECT id FROM orders " \
      "WHERE id = #{conn.quote(order_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id() " \
      "AND status NOT IN ('scheduled', 'rescheduled') " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Forbidden.new("order not found, not yours, or already rescheduled (one reschedule per order)") if order.nil?

    # ── Gate 2: settlement (capture receipt) referencing this order ──────────
    order_filter_json = [{ order_id: order_id.to_s }].to_json
    paid = conn.execute(
      "SELECT 1 AS ok " \
      "FROM kiosk.settlements pm " \
      "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
      "WHERE pm.user_id = kiosk.current_user_id() " \
      "AND cm.line_items @> #{conn.quote(order_filter_json)}::jsonb " \
      "LIMIT 1"
    ).first
    if paid.nil?
      raise Kiosk::Server::Errors::Forbidden.new(
        "this order is not paid yet — reschedule_delivery only moves an ALREADY-PAID order " \
        "(it reuses the existing settlement, it does not settle now). Pay for the order first " \
        "via the normal pay flow (a cart mandate whose line_items include " \
        "{\"order_id\": \"#{order_id}\"}), THEN call reschedule_delivery — or, if you have not paid, " \
        "just change the order in place with create_order(order_id: \"#{order_id}\", …)"
      )
    end

    # ── Compute slot_at from the shared source of truth (K-470) ──────────
    slot_at = DeliverySlots.slot_at(new_date, slot_id)

    # ── Update order ──────────────────────────────────────────────────────
    conn.execute(
      "UPDATE orders " \
      "SET status = 'rescheduled', slot_at = #{conn.quote(slot_at.iso8601)}::timestamptz, " \
      "    address = COALESCE(NULLIF(#{conn.quote(delivery_address.to_s)}, ''), address), updated_at = now() " \
      "WHERE id = #{conn.quote(order_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id()"
    )

    { order_id: order_id, rescheduled_at: slot_at.iso8601 }
  end
end

# request_kyc — start an 18+ verification at the KYC broker an EXTERNAL
# agent can COMPLETE without any pre-shared issuer key (design §5.1). Instead of
# minting a local token, getgrocery calls the broker's intake (server-to-server)
# with its own callback_url, the SINGLE claim it needs (age_over_18 — NOT a
# driving licence), and the agent's user_id as the subject the claim must bind
# to. The broker returns an unguessable verification_url (on the BROKER) and a
# request_id; getgrocery stores that request_id as this row's request_token (+
# the broker's nonce for callback anti-replay) and returns the broker's
# verification_url for the agent to relay to its human. On approve, the BROKER
# signs an anonymized {age_over_18} claim and POSTs it to getgrocery's POST
# /kyc/callback; the agent then polls `query kyc_status` and submits the returned
# jws to POST /kiosk/agents/kyc, then retries create_order for the alcohol cart.
Kiosk::Server::Actions.register("request_kyc",
  description: "Start an 18+ (age_over_18) verification for the authenticated principal — required only to " \
               "order an age_restricted (alcohol) item. Returns a verification_url to relay to your human to " \
               "approve (an anonymizing KYC broker confirms the fact and signs it — it never shares the " \
               "documents) and a request_id. After the human approves, poll `query kyc_status` with the " \
               "request_id for the signed attestation, submit it to POST /kiosk/agents/kyc, then retry " \
               "create_order. No pre-shared issuer key needed.",
  params: {}) do |_args|
  conn = ActiveRecord::Base.connection

  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  # Call the broker's intake server-to-server. getgrocery hands the broker its
  # own callback URL, the single claim it needs, and the agent's user_id (the
  # subject the signed claim must bind to). The broker mints the unguessable
  # request_id + verification_url on ITS side.
  callback_base = Kiosk.configuration.issuer.to_s.chomp("/")
  broker = ProveBrokerClient.start_verification(
    callback_url:     "#{callback_base}/kyc/callback",
    requested_claims: %w[age_over_18],
    subject_handle:   uid.to_s,
  )

  request_id       = broker.fetch("request_id")
  verification_url = broker.fetch("verification_url")
  nonce            = broker["nonce"].to_s

  # Store the BROKER's request_id as our local request_token so kyc_status
  # (below) polls it, plus the broker nonce the callback must echo.
  conn.execute(<<~SQL)
    INSERT INTO public.kyc_verification_requests
      (request_token, user_id, broker_nonce, status, created_at, updated_at)
    VALUES (#{conn.quote(request_id)}, #{conn.quote(uid)}::uuid, #{conn.quote(nonce)}, 'pending', now(), now())
  SQL

  {
    request_id:       request_id,
    verification_url: verification_url,
    status:           "pending",
  }
end

# kyc_status — poll a request_kyc verification the authenticated agent opened.
# Scoped to kiosk.current_user_id(): an agent can only read its OWN request, so
# it cannot poll (or lift the jws from) another agent's request.
#
# args: { request_id: <token from request_kyc> }
# Returns one row:
#   { status: "pending" }                         while the human has not acted
#   { status: "approved", kyc_jws: "<compact JWS>" } once approved — submit the
#     kyc_jws to POST /kiosk/agents/kyc, then retry create_order
#   { status: "declined" }                        if the human declined
Kiosk::Server::Queries.register("kyc_status",
  description: "Poll a request_kyc verification by its request_id. Returns {status: \"pending\"} until the " \
               "human acts; {status: \"approved\", kyc_jws} once approved (submit the kyc_jws to " \
               "POST /kiosk/agents/kyc, then retry create_order); {status: \"declined\"} if declined. " \
               "kyc_jws is a full compact JWS — a long, single-line, dot-separated token; submit the " \
               "ENTIRE value from this field, never a truncated console echo. " \
               "POLLING: while your human completes the verification, re-check every ~5 seconds for the " \
               "first minute, then every ~15 seconds, and GIVE UP after about 10 minutes — an identity " \
               "check can legitimately take that long, " \
               "but if it is still \"pending\" then, stop polling and tell your human it is not done yet " \
               "rather than polling indefinitely. The request_id stays pollable, so you can re-check later " \
               "(if the human's verification link has since expired, start a new request_kyc). " \
               "\"declined\" is TERMINAL: do not keep polling it — start a new request_kyc if the human " \
               "wants to try again.",
  params: { request_id: "string — the request_id returned by request_kyc" }) do |params|
  request_id = params[:request_id]
  if request_id.blank?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: request_id")
  end

  conn = ActiveRecord::Base.connection
  # Bound to the caller: user_id = kiosk.current_user_id() means an agent only
  # ever sees the status (and jws) of a request IT opened.
  row = conn.execute(
    "SELECT status, kyc_jws " \
    "FROM public.kyc_verification_requests " \
    "WHERE request_token = #{conn.quote(request_id.to_s)} " \
    "AND user_id = kiosk.current_user_id() " \
    "LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::NotFound.new("no such verification request for this principal") if row.nil?

  status = row["status"]
  if status == "approved"
    [{ "status" => "approved", "kyc_jws" => row["kyc_jws"] }]
  else
    [{ "status" => status }]
  end
end
