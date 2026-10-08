# frozen_string_literal: true

# Kiosk-demo (skooti-shape) configuration. Concrete values for the
# scooter-rental reference shape: uuid users, the engine's own agent IdP, Stripe,
# the KYC broker as the trusted KYC issuer, and the Ed25519 rental-token
# signing key the physical locks verify against.
#
# The verbs themselves are Rails controllers under app/controllers/kiosk/,
# named in `c.handlers` below, and their writes are Operations under
# app/operations/. What is left in this file is configuration — the PoW gate,
# the payment provider, the identity providers, the KYC trust anchors, the
# unlock key — which is what an initializer is for.

# Env posture (ephemeral dev signing key, PoW secret, issuer, unlock signing
# key, test flags) lives in config/environments/{development,test,production}.rb;
# this file reads the resolved values from Rails.configuration.x.kiosk.*.

require "openssl"


# Ed25519 rental-token signing key holder. The RentalTokenIssuer demo lib reads
# Kiosk.configuration.unlock_signing_key, and the neutral kiosk-server core
# carries no scooter-rental attribute — so the accessor is added to the config
# object here, for the initializer below to set and the issuer to read back.
module SkootiUnlockSigningKey
  attr_accessor :unlock_signing_key
end
Kiosk::Configuration.include(SkootiUnlockSigningKey)

# Registration PoW gate — a metered Equihash toll, tuned per provider. Params
# follow KIOSK_POW_DIFFICULTY (Kiosk::Pow::Equihash::Difficulty): low (default) →
# n=96 k=5, sub-second; high → n=168 k=7, ~1.3 GiB and ~10s on the reference
# numpy solver, so a poker on the hosted deploy feels the toll first-hand.
require "kiosk/pow/equihash"
require "kiosk/reputation"
require "kiosk/payment_providers/stripe"
require "kiosk/user_identity_providers/devise"
require "kiosk/kyc_providers/prove"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
SKOOTI_REGISTRATION_POW_PARAMS = Kiosk::Pow::Equihash::Difficulty.params

# ── PoW HMAC secret — the key the engine signs every challenge with ─────────
# Required in production, stable non-secret default in dev/test; posture in
# config/environments/*.
pow_secret = Rails.configuration.x.kiosk.pow_secret

# ── Ed25519 unlock signing key ──────────────────────────────────────────────
# The PEM is resolved per environment — dev/test read the shipped
# config/dev_unlock_key.pem, production requires KIOSK_UNLOCK_SIGNING_KEY_PEM —
# and this file only parses the resolved value. The empty case — a deleted or
# emptied dev key file — gets a signpost rather than a nil TypeError.
unlock_signing_key_pem = Rails.configuration.x.kiosk.unlock_signing_key_pem
if unlock_signing_key_pem.to_s.strip.empty?
  raise <<~MSG
    No unlock/rental-token signing key is configured, so this demo cannot
    sign the Ed25519 tokens its locks verify.

    config/environments/#{Rails.env}.rb reads config/dev_unlock_key.pem when
    KIOSK_UNLOCK_SIGNING_KEY_PEM is unset, and that file is missing or empty.
    Restore it with `git checkout config/dev_unlock_key.pem`, or set an
    explicit key:

      KIOSK_UNLOCK_SIGNING_KEY_PEM=$(openssl genpkey -algorithm ed25519)
  MSG
end
unlock_signing_key = OpenSSL::PKey.read(unlock_signing_key_pem)

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  # ── Where the wire verbs live ──────────────────────────────────────────────
  # Ordinary Rails controllers under app/controllers/kiosk/. This line only
  # NAMES them; the engine loads and registers them, re-running after every
  # development reload so an edited verb needs no restart. A verb registers when
  # its class LOADS and nothing loads a handler on its own, so an origin whose
  # controllers are not named here serves nothing at all.
  c.handlers = %w[Kiosk::FleetController Kiosk::RentalsController]

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in this demo). Set app_role to the same role so the
  # `GRANT TO app_role` statements in `enable_rls_on` are no-ops on a
  # role that already has all privileges via ownership.
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
  # here so an agent/reader sees the toll BEFORE it dials register (the 402
  # challenge params say the same, this is the up-front discovery signal).
  c.owner  = { name: "skooti", support: "demo@kiosk.tech" }
  if (notice = Kiosk::Pow::Equihash::Difficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: Kiosk::Pow::Equihash::Difficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.5.11.md"
  c.skill_sha256 = "039d25b152d02134478f20eb50089d87d679b481c3bcf2d0855fb8f0307c93ec"

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
  # link-code mint and unlink. ONE channel in every environment.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  # Where the engine bounces an unauthenticated browser visitor to the
  # account-binding pages. The engine stays IdP-neutral, so the URL is
  # supplied here; without it those pages render a bare 401.
  c.sign_in_path = "/users/sign_in"

  # Payment provider: Stripe in test mode (sk_test_…), card saved once on
  # Stripe's hosted page and charged off_session per reservation. With a mock
  # base URL configured (the demo tasks and CI, which carry no key) the SDK
  # talks to a local stripe-mock.
  key = Rails.configuration.x.kiosk.stripe_secret_key
  if (mock = Rails.configuration.x.kiosk.stripe_mock_url).present?
    require "stripe"
    Stripe.api_base = mock
  end
  raise "skooti requires STRIPE_SECRET_KEY (sk_test_…) or STRIPE_MOCK_URL" if key.blank?

  # One capture per reservation, and the cart checked against the price we
  # quoted before Stripe captures. Monetary only: ownership and KYC are
  # enforced at USE time (start_rental / rent_motorcycle).
  c.payment_provider = Kiosk::Server::PaymentClaim.new(
    Kiosk::PaymentProviders::Stripe.new(api_key: key, test_autocard: Rails.configuration.x.kiosk.test_autocard),
    currency: "eur", table: "reservations", reference: "reservation_id",
    query: "my_reservations", payer_column: "paid_by_user_id",
  )
  c.cart_price_checker = PriceChecker
  c.after_payment      = ->(reservation_id) { Reservation.paid!(reservation_id) }

  # Registration PoW gate: 1 Equihash proof to register. Prices bot registration
  # for a physical-service provider (each fresh identity pays compute up front).
  c.registration_pow_count  = 1
  c.registration_pow_params = SKOOTI_REGISTRATION_POW_PARAMS
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

  # ── KYC — the shared Prove broker ────────────────────────────────────
  # rent_motorcycle refuses until the person holds age_over_18 and licence_a.
  # The broker public key and intake secret come from config/environments with
  # no shipped fallback; without the secret this origin serves no KYC.
  prove_operator   = "skooti"
  prove_secret     = Rails.configuration.x.kiosk.prove_intake_secret
  c.kyc_provider   = Kiosk::KycProviders::Prove.new(operator_id: prove_operator, intake_secret: prove_secret) if prove_secret.present?
  c.kyc_claims     = %w[age_over_18 licence_a]
  c.kyc_issuer     = Kiosk::KycProviders::Prove.issuer
  c.kyc_public_key = Rails.configuration.x.kiosk.prove_public_key_pem
  c.kyc_audience   = prove_operator

  # ── Ed25519 rental-token signing key ──────────────────────────────────────
  # The key every offline rental token is signed with, and whose public half is
  # baked into each lock at provisioning. dev/test load the fixed keypair at
  # config/dev_unlock_key.pem; production REFUSES TO BOOT without
  # KIOSK_UNLOCK_SIGNING_KEY_PEM.
  #
  # config/dev_unlock_key.pem is a FIXTURE, never a production signer: it is
  # tracked in this public repo, so any clone holds its private half and could
  # mint a token that opens a scooter.
  c.unlock_signing_key = unlock_signing_key
end

