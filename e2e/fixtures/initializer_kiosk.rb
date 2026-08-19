# frozen_string_literal: true

# E2E-specific Kiosk configuration. Overrides the generator-produced
# initializer (which has commented-out fields) with concrete values for
# the demo: synthetic users (uuid), stub IdP, two handler controllers.
#
# THE VERBS ARE NOT HERE (T-081). They are ordinary Rails controllers under
# app/controllers/kiosk/ — Kiosk::CatalogController (salons, my_appointments)
# and Kiosk::BookingsController (book_appointment) — named in `c.handlers`
# below, which is how the engine finds them. What is left in this file is
# configuration, which is what an initializer is for.

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/stub_user_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")

# Registration PoW gate uses Equihash (one PoW = Equihash). Small demo params
# (n=96 k=5, matching the demos) keep the register solve well under a second.
# PoW is a metered toll, tuned per provider — here it prices bot registration
# on the e2e golden path so the harness exercises the real 402 → solve → retry
# handshake, not a toll-free shortcut.
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
E2E_REGISTRATION_POW_PARAMS = { n: 96, k: 5 }.freeze

# ── PoW HMAC secret — REQUIRED outside development/test (K-541) ────────────
# pow_secret is the HMAC key the engine signs every PoW challenge with. This
# repo is PUBLIC, so a shipped fallback would be world-readable: a reader could
# mint a self-signed challenge at trivial difficulty {n:8,k:1} and forge a proof
# the server accepts — silently turning proof-of-work OFF. It MUST come from the
# environment in production and fail LOUD when absent, matching the signing key.
# The e2e harness boots development, so it keeps a stable (non-secret) default; a
# too-short secret is rejected everywhere.
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
  "e2e-demo-pow-secret-dev-insecure-default"
end
raise "KIOSK_POW_SECRET must be at least 32 bytes (got #{pow_secret.bytesize}) — generate one with `openssl rand -hex 32`." if pow_secret.bytesize < 32

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # Path C: RLS is optional; no enable_rls_on in this fixture. app_role /
  # system_role are kept for the `run.sh` role pre-creation step (harmless).
  #
  # NOTE (load-bearing): `c.system_role=` is defined ONLY by
  # Kiosk::RLS::ConfigurationExtension (kiosk-rls), which run.sh installs via
  # a path override even though RLS itself is unused here. `app_role` is a
  # kiosk-core attr; `system_role` is not — so this line is why the Gemfile
  # `gem "kiosk-rls"` entry in run.sh is mandatory: dropping the gem makes
  # this call raise NoMethodError at boot.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3001")
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  c.owner  = { name: "Combette E2E Demo", support: "demo@kiosk.tech" }

  # Registration PoW gate: 1 Equihash proof to register. POST /kiosk/auth/register
  # returns 402 pow_required until a valid proof is attached (assistant.sh solves
  # it with the bundled kiosk-pow-equihash/solve.py). Same mechanism the demos use.
  c.registration_pow_count  = 1
  c.registration_pow_params = E2E_REGISTRATION_POW_PARAMS
  c.pow_secret              = pow_secret

  # JwtOrStubIdp tries kiosk-pop JWTs (minted by the bundled IdP's
  # register/login) first, then falls back to StubIdp's bespoke
  # `agent:u-…:a-…:r-…` shape. The account-binding token poll mints the
  # same kiosk JWTs, so bound assistants authenticate through the JWT path
  # too. One endpoint authenticates both for the e2e suite.
  c.agent_idp = JwtOrStubIdp.new(stub: Rails.env.local? ? StubIdp.new : nil)
  # The provider's own web-session channel: authenticates the approving
  # human on the account-binding pages (device verify, link mint, unlink).
  # DEV/TEST ONLY (K-555): the stub parses an UNSIGNED, self-asserted
  # `user:u-<uuid>` bearer, so it is wired only under Rails.env.local? (the
  # e2e harness boots in development); in production user_idp is nil.
  c.user_idp = Rails.env.local? ? StubUserIdp.new : nil

  c.payment_provider = StubPsp.new

  # The handler controllers, by NAME. This line is load-bearing and there is no
  # convention that replaces it: the wire reaches a handler through the
  # registry, nothing else in the app ever references these classes, and this
  # harness boots DEVELOPMENT (eager_load = false), so without it Zeitwerk never
  # loads them, the registry stays empty, and the origin answers `GET
  # /kiosk/schema` with `queries=[] actions=[]`, 404s every query and run, and
  # advertises `"capabilities": []` (K-761).
  c.handlers = %w[Kiosk::CatalogController Kiosk::BookingsController]

  # Request-shape validation ON, as all seven demos have it. Two things ride
  # on it: a malformed Kiosk-PoW proof answers a clear 400 instead of a silent
  # re-challenge loop (K-479), and — since the 0.4 per-verb wire — a verb's
  # declared `input_schema` VALIDATES the arguments of every request to it
  # rather than merely describing them, so the harness's reserved-name and
  # closed-schema assertions are testing the real path. Needs `json_schemer`,
  # which run.sh adds to the generated app's Gemfile.
  c.validate_requests = true
end
