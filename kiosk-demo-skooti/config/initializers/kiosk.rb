# frozen_string_literal: true

# Kiosk-demo (skooti-shape) configuration. Concrete values for the
# scooter-rental reference shape: uuid users, the engine's own agent IdP, StubPsp,
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
# follow KIOSK_POW_DIFFICULTY (app/services/pow_difficulty.rb): low (default) →
# n=96 k=5, sub-second; high → n=168 k=7, ~1.3 GiB and ~10s on the reference
# numpy solver, so a poker on the hosted deploy feels the toll first-hand.
require "kiosk/pow/equihash"
require "kiosk/reputation"
require "kiosk/user_identity_providers/devise"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
SKOOTI_REGISTRATION_POW_PARAMS = PowDifficulty.params

# ── PoW HMAC secret — the key the engine signs every challenge with ─────────
# Required in production, stable non-secret default in dev/test; posture in
# config/environments/*.
pow_secret = Rails.configuration.x.kiosk.pow_secret

# ── Ed25519 unlock signing key ──────────────────────────────────────────────
# The PEM is resolved per environment — dev/test read the shipped
# config/dev_unlock_key.pem, production requires KIOSK_UNLOCK_SIGNING_KEY_PEM —
# and this file only parses the resolved value.
#
# The empty case gets a SIGNPOST rather than a nil TypeError. Production keys
# the KIOSK_UNLOCK_SIGNING_KEY_PEM requirement off the mere existence of
# config/dev_unlock_key.pem, so stripping that file from a deploy artifact — a
# plausible reaction to "stop shipping a dev private key" — makes production
# stop ASKING for the variable and leave the config nil. Without the raise
# below this line dies with `TypeError: no implicit conversion of nil into
# String`, naming neither the file nor the fix.
unlock_signing_key_pem = Rails.configuration.x.kiosk.unlock_signing_key_pem
if unlock_signing_key_pem.to_s.strip.empty?
  raise <<~MSG
    No unlock/rental-token signing key is configured, so this demo cannot
    sign the Ed25519 tokens its locks verify.

    config/environments/#{Rails.env}.rb resolves it, and every path it has
    came back empty:

      * production REQUIRES KIOSK_UNLOCK_SIGNING_KEY_PEM — but only for a
        demo that ships config/dev_unlock_key.pem, the marker it keys that
        requirement off. If that file was stripped from the deploy artifact,
        the variable is silently no longer demanded and you land HERE.
        Restore the tracked file (it is a marker, not a fallback — its key is
        never loaded in production) and set the variable.
      * development/test fall back to reading that same file, so a deleted
        or emptied copy lands here too. Restore it with
        `git checkout config/dev_unlock_key.pem`.

    Either way an explicit key also satisfies this line:

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
  # development reload so an edited verb needs no restart.
  # restart). A verb registers when its class LOADS and nothing loads a handler
  # on its own, so an origin whose controllers are not named here serves
  # nothing at all.
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
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.4.12.md"
  c.skill_sha256 = "7d5be9bf841f8e05fd67b62b60d140fab584de373f8e28944298c93139f9a9ca"

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

  # Payment provider — stub for the demo; swap in kiosk-pay-stripe for real.
  # The cashier check: ValidatingRentalProvider verifies the agent-signed cart
  # against OUR quote — currency (EUR), single reservation reference, and the
  # per-minute price the operator quoted for that reservation — before the
  # wrapped StubPsp captures anything. Monetary only: reservation→payer
  # ownership and KYC are enforced at USE time (start_rental / rent_motorcycle),
  # not here.
  c.payment_provider = ValidatingRentalProvider.new(StubPsp.new, currency: "eur")

  # Registration PoW gate: 1 Equihash proof to register. Prices bot registration
  # for a physical-service provider (each fresh identity pays compute up front).
  c.registration_pow_count  = 1
  c.registration_pow_params = SKOOTI_REGISTRATION_POW_PARAMS
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

  # KYC attestation verifier — trusts the KYC broker (the shared anonymizing
  # KYC issuer). skooti hosts no issuer of its own: it configures the broker as
  # its kyc_issuer + kyc_public_key ONCE and asks the broker for exactly the
  # claims it needs (age_over_18 + licence_a). The issuer identity comes from
  # ProveTrust; the broker PUBLIC KEY comes from Rails.configuration.x.kiosk
  # (config/environments): the harness/rake tasks and the deploy pin it
  # explicitly, there is NO shipped fallback key, and with none set the
  # engine's KycVerifier fails closed at the wire.
  c.kyc_issuer    = ProveTrust.issuer
  c.kyc_public_key = Rails.configuration.x.kiosk.prove_public_key_pem
  # OPERATOR-BINDING (aud): the engine KycVerifier REJECTS at the wire any
  # attestation whose `aud` != this operator's kyc_audience — so a claim the
  # broker minted for another operator cannot unlock skooti even before skooti's
  # callback-layer operator check runs. skooti declares its stable broker handle
  # ("skooti") as the audience (the broker mints `aud` = the audience skooti sends
  # at intake), not its per-deploy origin URL, so the value is stable across the
  # 127.0.0.1 / skooti.demo.kiosk.tech harness ports.
  c.kyc_audience  = ProveTrust.operator_id

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

