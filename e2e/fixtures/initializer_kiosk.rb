# frozen_string_literal: true

# E2E-specific Kiosk configuration. Overrides the generator-produced
# initializer (which has commented-out fields) with concrete values for
# the demo: synthetic users (uuid), stub IdP, one Action registered.

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
  c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET", "e2e-demo-pow-secret")

  # JwtOrStubIdp tries kiosk-pop JWTs (minted by the bundled IdP's
  # register/login) first, then falls back to StubIdp's bespoke
  # `agent:u-…:a-…:r-…` shape. The account-binding token poll mints the
  # same kiosk JWTs, so bound assistants authenticate through the JWT path
  # too. One endpoint authenticates both for the e2e suite.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # The provider's own web-session channel: authenticates the approving
  # human on the account-binding pages (device verify, link mint, unlink).
  c.user_idp = StubUserIdp.new

  c.payment_provider = StubPsp.new
end

# ─── Queries ────────────────────────────────────────────────────────────────

# salons — public catalog. Any authenticated agent can browse.
# No per-user scoping: the WHERE is provider-controlled and always TRUE.
Kiosk::Server::Queries.register("salons", description: "List all bookable salons (public catalog).", params: {}) do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, name FROM salons ORDER BY id"
  ).to_a
end

# my_appointments — per-user appointment list scoped by the session GUC.
# The WHERE is provider-controlled; the agent supplies no user filter.
# App-layer per-user isolation without RLS: the principal sees only rows
# where user_id matches kiosk.current_user_id(), enforced in the query.
Kiosk::Server::Queries.register("my_appointments", description: "List the calling principal's own appointments.", params: {}) do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, salon_id, slot FROM appointments " \
    "WHERE user_id = kiosk.current_user_id() " \
    "ORDER BY id"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

# Register the demo Action. A registered name + block IS the shipped v0.1
# Action API — the same `Kiosk::Server::Actions.register` call the five demo
# apps use. The richer `Kiosk::Action` DSL (accepts/requires_payment/
# escalate_to) is a post-v0.1 follow-up and does not exist yet.
Kiosk::Server::Actions.register("book_appointment", description: "Book an appointment at a salon for a given slot.", params: {
  salon_id: "integer — id of the salon (from the `salons` query)",
  slot:     "string — appointment time as an ISO 8601 timestamp",
}) do |args|
  # Identity is set via Kiosk::Server::SessionContext SET LOCAL —
  # current_user_id() helper returns the principal. ActiveRecord doesn't
  # have direct access; pull from PG.
  user_id = ActiveRecord::Base.connection.execute(
    "SELECT kiosk.current_user_id() AS uid"
  ).first["uid"]

  appointment = Appointment.create!(
    user_id:  user_id,
    salon_id: args[:salon_id],
    slot:     args[:slot],
  )

  { appointment_id: appointment.id, salon_id: appointment.salon_id, slot: appointment.slot.iso8601 }
end
