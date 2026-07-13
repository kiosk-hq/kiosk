# frozen_string_literal: true

# Kiosk-demo (Combette-shape) configuration. Concrete values for the
# salon-booking reference shape: uuid users, JWT-or-stub IdP, one
# Action registered (book_appointment).

# ── Ephemeral dev signing key (K-034) ────────────────────────────────────
# JWT / register flows need a signing key. In development or test, if none is
# provided, self-provision an EPHEMERAL RSA key so `demo:setup` and the flows
# run out-of-the-box. Never do this in production — a real key must be set.
if ENV["KIOSK_SIGNING_KEY_B64"].nil? && ENV["KIOSK_SIGNING_KEY_PEM"].nil? && Rails.env.local?
  require "openssl"
  require "base64"
  ENV["KIOSK_SIGNING_KEY_B64"] = Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)
  warn "[kiosk] WARNING: generated an EPHEMERAL signing key (#{Rails.env}); set KIOSK_SIGNING_KEY_B64/PEM for a stable key."
end

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")

# Registration PoW gate (KIOSK_POW_REGISTER_DEMO=1). A booking SaaS can price
# fresh-identity minting: registering an agent costs one Equihash proof
# (ADR-0001 amended — one PoW = Equihash; ADR-0007 — a metered toll). Small demo
# params solve sub-second. Off by default so the walkthrough/isolation flows are
# unchanged.
SAAS_REGISTRATION_POW_PARAMS = { n: 96, k: 5 }.freeze
if ENV["KIOSK_POW_REGISTER_DEMO"] == "1"
  require "kiosk/pow/equihash"
  require "kiosk/reputation"
  Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
end

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in v0.1 alpha). Set app_role to the same role so the
  # `GRANT TO app_role` statements in `enable_rls_on` are no-ops on a
  # role that already has all privileges via ownership.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3001")
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  c.owner  = { name: "Combette on Park (Kiosk demo)", support: "demo@kiosk.tech" }
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_sha256 = "7cd44398e6102c20ea95484c1fe03df68907545c4c21412b18bd559226ed95c9"

  # JwtOrStubIdp tries Kiosk-issued JWTs (kiosk-pop register/login output;
  # OAuth device-grant dormant per ADR-0008) first,
  # then falls back to StubIdp's bespoke `agent:u-…:a-…:r-…` shape.
  # One endpoint authenticates both for the demo. Real providers swap
  # in `kiosk-user-idp-devise` (or another adapter); see the README.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # user_idp not needed — composite handles both channels.

  # ── Registration PoW gate (active only when KIOSK_POW_REGISTER_DEMO=1) ───
  if ENV["KIOSK_POW_REGISTER_DEMO"] == "1"
    c.registration_pow_count  = 1
    c.registration_pow_params = SAAS_REGISTRATION_POW_PARAMS
    c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET", "saas-demo-pow-secret")
  end
end

# ─── Queries ────────────────────────────────────────────────────────────────

# salons — full salon catalogue; no per-user scoping, any authenticated
# principal may browse (mirrors the public SELECT policy previously in RLS).
Kiosk::Server::Queries.register("salons",
                                 description: "Browse the public salon catalogue",
                                 params: {}) do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, name FROM salons ORDER BY id"
  ).to_a
end

# my_appointments — per-user appointment list scoped by the session GUC.
# App-layer isolation: the agent supplies no filter; the WHERE is
# provider-controlled and cannot be bypassed by the caller.
Kiosk::Server::Queries.register("my_appointments",
                                 description: "List this principal's appointments (scoped to authenticated user via kiosk.current_user_id())",
                                 params: {}) do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, salon_id, slot FROM appointments " \
    "WHERE user_id = kiosk.current_user_id() " \
    "ORDER BY id"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

# Register the demo Action. In production, providers use the full
# `Kiosk::Action` DSL (post-v0.1); for the e2e a simple registered
# block is sufficient.
Kiosk::Server::Actions.register("book_appointment",
                                 description: "Book an appointment at a salon for the authenticated principal",
                                 params: {
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
