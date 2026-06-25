# frozen_string_literal: true

# E2E-specific Kiosk configuration. Overrides the generator-produced
# initializer (which has commented-out fields) with concrete values for
# the demo: synthetic users (uuid), stub IdP, one Action registered.

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # Path C: RLS is optional; no enable_rls_on in this fixture. app_role /
  # system_role are kept for the `run.sh` pre-creation step (harmless).
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3001")
  c.roles  = %i[customer]
  c.owner  = { name: "Combette E2E Demo", support: "demo@kiosk.tech" }

  # JwtOrStubIdp tries Kiosk-issued JWTs (Device-Grant output) first,
  # then falls back to StubIdp's bespoke `agent:u-…:a-…:r-…` shape.
  # One endpoint authenticates both for the e2e suite.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # user_idp not needed — composite handles both channels.

  c.payment_provider = StubPsp.new
end

# ─── Queries ────────────────────────────────────────────────────────────────

# salons — public catalog. Any authenticated agent can browse.
# No per-user scoping: the WHERE is provider-controlled and always TRUE.
Kiosk::Server::Queries.register("salons") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, name FROM salons ORDER BY id"
  ).to_a
end

# my_appointments — per-user appointment list scoped by the session GUC.
# The WHERE is provider-controlled; the agent supplies no user filter.
# App-layer per-user isolation without RLS: the principal sees only rows
# where user_id matches kiosk.current_user_id(), enforced in the query.
Kiosk::Server::Queries.register("my_appointments") do |_params|
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
Kiosk::Server::Actions.register("book_appointment") do |args|
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
