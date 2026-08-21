# frozen_string_literal: true

# Kiosk-demo (skooti-shape) configuration. Concrete values for the
# scooter-rental reference shape: uuid users, JWT-or-stub IdP, StubPsp,
# the KYC broker as the trusted KYC issuer, and the Ed25519 rental-token
# signing key the physical locks verify against.
#
# The verbs THEMSELVES are not here any more (T-057 / K-654): they are Rails
# controllers under app/controllers/kiosk/, named in `c.handlers` below, and
# their writes are Operations under app/operations/. What is left in this file
# is configuration — the PoW gate, the payment provider, the identity
# providers, the KYC trust anchors, the unlock key — which is what an
# initializer is for.

# Env posture (ephemeral dev signing key, PoW secret, issuer, unlock signing
# key, test flags) lives in config/environments/{development,test,production}.rb
# (K-650/K-686); this file reads the resolved values from
# Rails.configuration.x.kiosk.*.

require "openssl"


# Ed25519 rental-token signing key holder. The RentalTokenIssuer demo lib
# reads Kiosk.configuration.unlock_signing_key; the neutral kiosk-server core
# no longer carries this scooter-rental attribute (it moved here with the
# issuer). Re-add the accessor to the config object so the initializer below
# can set it and the issuer can read it back.
module SkootiUnlockSigningKey
  attr_accessor :unlock_signing_key
end
Kiosk::Configuration.include(SkootiUnlockSigningKey)

# Registration PoW gate uses Equihash (one PoW = Equihash;
# the old SHA256 hashcash is gone). PoW is a metered toll, tuned per provider.
#
# Params are chosen by KIOSK_POW_DIFFICULTY (app/services/pow_difficulty.rb):
#   low  (default) → n=96 k=5  — sub-second solve; CI/local stay fast.
#   high           → n=168 k=7 — genuinely memory+CPU-intensive (~10s / ~1.3 GiB)
#                    for the hosted deploy, so a poker feels the toll first-hand.
# Unset = low, so this demo's flows and CI register at the fast params.
require "kiosk/pow/equihash"
require "kiosk/reputation"
require "kiosk/user_identity_providers/devise"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
SKOOTI_REGISTRATION_POW_PARAMS = PowDifficulty.params

# ── PoW HMAC secret (K-541/K-650) ───────────────────────────────────────────
# The HMAC key the engine signs every PoW challenge with. Required in
# production, stable (non-secret) default in dev/test — that posture lives in
# config/environments/*; here we only read the resolved value.
pow_secret = Rails.configuration.x.kiosk.pow_secret

# ── Ed25519 unlock signing key (K-686/K-650) ────────────────────────────────
# Same shape: the PEM is resolved per environment (dev/test read the shipped
# config/dev_unlock_key.pem, production requires KIOSK_UNLOCK_SIGNING_KEY_PEM
# and crash-checks it at boot), and this file only parses the resolved value.
# Never DevUnlockKey and never ENV here — the posture is the environment
# file's to state, not an initializer's.
#
# The empty case gets a SIGNPOST, not a nil TypeError — the ProveKey.config
# shape (kiosk-demo-prove/lib/prove_key.rb). Every environment's resolution
# hangs off config/dev_unlock_key.pem: dev/test read it, and production keys
# the KIOSK_UNLOCK_SIGNING_KEY_PEM requirement off its mere existence (that
# byte-identical file may not name a demo, so the marker stands in for the
# name). Strip that file from a deploy artifact — a plausible reaction to
# "stop shipping a dev private key" — and production stops ASKING for the
# variable, leaves the config nil, and this line used to die with
# `TypeError: no implicit conversion of nil into String`, naming neither the
# file nor the fix. That is the K-681 failure mode, one app over.
unlock_signing_key_pem = Rails.configuration.x.kiosk.unlock_signing_key_pem
if unlock_signing_key_pem.to_s.strip.empty?
  raise <<~MSG
    No unlock/rental-token signing key is configured, so this demo cannot
    sign the Ed25519 tokens its locks verify (K-686).

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

  # ── Where the wire verbs live (T-053 mixin / T-057) ────────────────────────
  # The three queries and five actions are ordinary Rails controllers under
  # app/controllers/kiosk/ — `include Kiosk::Query` / `include Kiosk::Action`,
  # class-level macros, plain `render json:`. Nothing about them belongs in an
  # initializer, and nothing about them is here: this line only NAMES them, and
  # the engine loads and registers them (once in production, again after every
  # reload in development, so an edited/added/removed verb needs no restart).
  # A verb registers when its class LOADS and nothing loads a handler on its own,
  # so an origin whose controllers are not named here serves nothing at all
  # (K-761).
  c.handlers = %w[Kiosk::FleetController Kiosk::RentalsController]

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in this demo). Set app_role to the same role so the
  # `GRANT TO app_role` statements in `enable_rls_on` are no-ops on a
  # role that already has all privileges via ownership.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

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
  # here so an agent/reader sees the toll BEFORE it dials register (the 402
  # challenge params say the same, this is the up-front discovery signal).
  c.owner  = { name: "skooti", support: "demo@kiosk.tech" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.4.3.md"
  c.skill_sha256 = "2f302cf68429375797f3b1ad34d9484e0b60f1fa31e2078f02e38cee848ae993"

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

  # KYC attestation verifier — trusts the KYC broker (the shared
  # anonymizing KYC issuer). skooti no longer hosts its own issuer: it configures
  # the broker as its kyc_issuer + kyc_public_key ONCE (design §5.3) and asks the
  # broker for exactly the claims it needs (age_over_18 + licence_a). The issuer
  # identity comes from ProveTrust; the broker PUBLIC KEY comes from
  # Rails.configuration.x.kiosk (config/environments — K-650): the harness/rake
  # tasks and the deploy pin it explicitly, there is NO shipped fallback key,
  # and with none set the engine's KycVerifier fails closed at the wire.
  c.kyc_issuer    = ProveTrust.issuer
  c.kyc_public_key = Rails.configuration.x.kiosk.prove_public_key_pem
  # OPERATOR-BINDING (aud): the engine KycVerifier now REJECTS at the wire any
  # attestation whose `aud` != this operator's kyc_audience — so a claim the
  # broker minted for another operator cannot unlock skooti even before skooti's
  # callback-layer operator check runs. skooti declares its stable broker handle
  # ("skooti") as the audience (the broker mints `aud` = the audience skooti sends
  # at intake), not its per-deploy origin URL, so the value is stable across the
  # 127.0.0.1 / skooti.demo.kiosk.tech harness ports.
  c.kyc_audience  = ProveTrust.operator_id

  # ── Ed25519 rental-token signing key (K-686/K-650) ────────────────────────
  # The key every offline rental token is signed with, and whose public half is
  # baked into each lock at provisioning. Resolved per environment
  # (config/environments/*, read as config.x.kiosk above): dev/test load the
  # fixed keypair shipped at config/dev_unlock_key.pem — stable vectors, and
  # the lock the flow drivers provision matches — while production REFUSES TO
  # BOOT without KIOSK_UNLOCK_SIGNING_KEY_PEM.
  #
  # It read `DevUnlockKey.private_key` here until K-686 — unconditionally, in
  # every environment, under a comment promising an env-loaded PEM in
  # production that nothing ever supplied. The private half of the key every
  # provisioned lock trusts therefore shipped in this public repo AND was the
  # live production signer: any clone could mint a token that opens a scooter.
  c.unlock_signing_key = unlock_signing_key
end

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  SKOOTI_VERB_MAP = {
    "reserve"         => "reserved",
    "start_rental"    => "ran",
    "rent_motorcycle" => "ran",
    "payment_setup"   => "ran",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: SKOOTI_VERB_MAP,
  )
end

