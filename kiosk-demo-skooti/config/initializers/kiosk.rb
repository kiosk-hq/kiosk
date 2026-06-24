# frozen_string_literal: true

# Kiosk-demo (skooti-shape) configuration. Concrete values for the
# scooter-rental reference shape: uuid users, JWT-or-stub IdP, StubPsp,
# StubKyc, two Actions registered (reserve, unlock).

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")
require Rails.root.join("lib/stub_kyc")

# Inject the RLS DSL into ActiveRecord::Migration so that migrations can
# call `enable_rls_on TABLE do ... end` directly. The kiosk-rls README
# documents this opt-in; auto-injection from the gem itself lands in a
# follow-up.
ActiveRecord::Migration.include(Kiosk::RLS::DSL)

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

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3003")
  c.roles  = %i[customer]
  c.owner  = { name: "skooti", support: "help@skooti.app" }

  # JwtOrStubIdp tries Kiosk-issued JWTs (Device-Grant output) first,
  # then falls back to StubIdp's bespoke `agent:u-…:a-…:r-…` shape.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)

  # Payment provider — stub for the demo; swap in kiosk-pay-stripe for real.
  c.payment_provider = StubPsp.new

  # PoW gate: ~20 bits ≈ <1 s to solve on a modern CPU. Filters bot registration.
  c.registration_difficulty = 20

  # KYC attestation verifier — trusts the stub KYC provider.
  c.kyc_issuer    = "https://kyc.example"
  c.kyc_public_key = StubKyc.public_key

  # Per-lock HMAC key derivation master secret.
  c.unlock_master_key = ENV.fetch("SKOOTI_MASTER_KEY", "dev-master-key-0001")
end

# ─── Actions ────────────────────────────────────────────────────────────────

# reserve — create a scooter reservation row for the authenticated user.
#
# args: { scooter_code: <string, e.g. "SK-001"> }
# Returns: { reservation_id:, scooter_code:, price_per_min_cents: }
#
# Runs inside SessionContext (the Executor wraps `run` in a transaction with
# the four SET LOCAL GUCs already applied), so kiosk.current_user_id() is live.
Kiosk::Server::Actions.register("reserve") do |args|
  conn = ActiveRecord::Base.connection

  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  scooter_code = args.fetch(:scooter_code) { raise Kiosk::Server::Errors::BadRequest.new("missing field: scooter_code") }

  scooter = conn.execute(
    "SELECT id, code, price_per_min_cents FROM scooters WHERE code = #{conn.quote(scooter_code.to_s)} LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::BadRequest.new("scooter not found: #{scooter_code}") if scooter.nil?

  reservation = conn.execute(<<~SQL).first
    INSERT INTO public.reservations (user_id, scooter_id, status, created_at, updated_at)
    VALUES (#{conn.quote(uid)}::uuid, #{conn.quote(scooter["id"].to_s)}::integer, 'reserved', now(), now())
    RETURNING id
  SQL

  {
    reservation_id:      reservation["id"],
    scooter_code:        scooter["code"],
    price_per_min_cents: scooter["price_per_min_cents"],
  }
end

# unlock — verify gates then issue an HMAC unlock MAC for the scooter lock.
#
# args: { reservation_id:, nonce: (hex) }
# scooter_id is NOT accepted from the client — it is derived server-side from
# the reservation row, preventing cross-scooter unlock attacks.
# Gates (all three must pass, else 403 Forbidden):
#   1. reservation exists and belongs to the principal (RLS-scoped SELECT)
#   2. agent is KYC-verified (kyc_verified_at NOT NULL in kiosk.agents)
#   3. principal has a settled payment mandate
# Returns: { scooter_code:, mac:, alg: "HMAC-SHA256" }
Kiosk::Server::Actions.register("unlock") do |args|
  conn = ActiveRecord::Base.connection

  nonce_hex      = args[:nonce]
  reservation_id = args[:reservation_id]

  if nonce_hex.nil? || nonce_hex.to_s.empty?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: nonce")
  end
  if reservation_id.nil? || reservation_id.to_s.empty?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: reservation_id")
  end

  # ── Gate 1: reservation belongs to the principal (explicit ownership) ──
  # C1: AND user_id = kiosk.current_user_id() added explicitly so that a
  # foreign reservation UUID returns nothing even if RLS is inactive.
  # C3: require status = 'reserved' so a reservation already 'active' (ride
  # in progress) is rejected here — re-unlock-during-a-ride is a future
  # feature that needs a ride-session token.
  # The scooter_id FK is read server-side — the client cannot supply it.
  reservation = conn.execute(
    "SELECT id, scooter_id FROM public.reservations " \
    "WHERE id = #{conn.quote(reservation_id.to_s)}::uuid " \
    "AND user_id = kiosk.current_user_id() " \
    "AND status = 'reserved' " \
    "LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::Forbidden.new("reservation not found or not yours") if reservation.nil?

  # Derive the authoritative scooter code from the reservation's FK.
  # This binds the MAC to the ACTUAL reserved scooter, not a client-supplied value.
  scooter_row = conn.execute(
    "SELECT code FROM scooters WHERE id = #{conn.quote(reservation["scooter_id"].to_s)} LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::Forbidden.new("scooter not found for reservation") if scooter_row.nil?

  code = scooter_row["code"]

  # ── Gate 2: agent is KYC-verified ──────────────────────────────────────
  # kiosk.current_agent_id() reads the app.current_agent_id GUC set by
  # SessionContext — always present when the request is agent-authenticated.
  kyc_row = conn.execute(<<~SQL).first
    SELECT kyc_verified_at
    FROM kiosk.agents
    WHERE id = kiosk.current_agent_id()
      AND revoked_at IS NULL
  SQL
  if kyc_row.nil? || kyc_row["kyc_verified_at"].nil?
    raise Kiosk::Server::Errors::Forbidden.new("agent is not KYC-verified")
  end

  # ── Gate 3: settled payment whose cart references THIS reservation ───────
  # C2: join payment_mandates → cart_mandates and require that line_items
  # contains the reservation_id of this specific reservation. This prevents
  # a user from paying for reservation A and unlocking reservation B.
  # The JSONB literal is built server-side; reservation_id is a UUID string.
  # to_json on a Ruby Hash produces a valid JSON object; embed it as the
  # sole element of a JSON array and cast to jsonb for the @> containment check.
  resv_filter_json = [{ reservation_id: reservation_id.to_s }].to_json
  paid = conn.execute(
    "SELECT 1 AS ok " \
    "FROM kiosk.payment_mandates pm " \
    "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
    "WHERE pm.user_id = kiosk.current_user_id() " \
    "AND cm.line_items @> #{conn.quote(resv_filter_json)}::jsonb " \
    "LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::Forbidden.new("no settled payment mandate for this reservation") if paid.nil?

  # ── All gates passed: compute and return the unlock MAC ─────────────────
  # MAC is bound to the server-derived scooter code, not any client-supplied value.
  mac = Kiosk::Server::UnlockAuthority.mac(
    scooter_id:     code,
    nonce_hex:      nonce_hex.to_s,
    reservation_id: reservation_id.to_s,
  )

  # Mark the reservation active.
  conn.execute(
    "UPDATE public.reservations SET status = 'active' WHERE id = #{conn.quote(reservation_id.to_s)}::uuid"
  )

  {
    scooter_code: code,
    mac:          mac,
    alg:          "HMAC-SHA256",
  }
end
