# frozen_string_literal: true

# Kiosk-demo (skooti-shape) configuration. Concrete values for the
# scooter-rental reference shape: uuid users, JWT-or-stub IdP, StubPsp,
# StubKyc, Actions (reserve, start_rental, payment_setup) + named queries
# (scooters_available, my_reservations).

# ── Ephemeral dev signing key ────────────────────────────────────────────
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
require Rails.root.join("lib/stub_user_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")
require Rails.root.join("lib/stub_kyc")
require Rails.root.join("lib/dev_unlock_key")
require Rails.root.join("lib/rental_token_issuer")

# Ed25519 rental-token signing key holder. The RentalTokenIssuer demo lib
# reads Kiosk.configuration.unlock_signing_key; the neutral kiosk-server core
# no longer carries this scooter-rental attribute (it moved here with the
# issuer). Re-add the accessor to the config object so the initializer below
# can set it and the issuer can read it back.
module SkootiUnlockSigningKey
  attr_accessor :unlock_signing_key
end
Kiosk::Configuration.include(SkootiUnlockSigningKey)

# Inject the RLS DSL into ActiveRecord::Migration so that migrations can
# call `enable_rls_on TABLE do ... end` directly. The kiosk-rls README
# documents this opt-in; auto-injection from the gem itself lands in a
# follow-up.
ActiveRecord::Migration.include(Kiosk::RLS::DSL)

# Registration PoW gate uses Equihash (one PoW = Equihash;
# the old SHA256 hashcash is gone). Small demo params keep the register solve
# well under a second. PoW is a metered toll, tuned per provider.
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
SKOOTI_REGISTRATION_POW_PARAMS = { n: 96, k: 5 }.freeze

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
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  c.owner  = { name: "skooti", support: "help@skooti.app" }
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.1.md"
  c.skill_sha256 = "2cb4a2d4d8718be877975ded8b0b55be647850e340e848aeb2b0c4ec04cec698"

  # JwtOrStubIdp tries Kiosk-issued JWTs (kiosk-pop register/login output;
  # OAuth device-grant dormant) first,
  # then falls back to StubIdp's bespoke `agent:u-…:a-…:r-…` shape.
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # The web-session channel for the account-binding surfaces (verify
  # page, link mint, unlink) — see lib/stub_user_idp.rb for the scope.
  c.user_idp = StubUserIdp.new

  # Payment provider — stub for the demo; swap in kiosk-pay-stripe for real.
  c.payment_provider = StubPsp.new

  # Registration PoW gate: 1 Equihash proof to register. Prices bot registration
  # for a physical-service provider (each fresh identity pays compute up front).
  c.registration_pow_count  = 1
  c.registration_pow_params = SKOOTI_REGISTRATION_POW_PARAMS
  c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET", "skooti-demo-pow-secret")

  # KYC attestation verifier — trusts the stub KYC provider.
  c.kyc_issuer    = "https://kyc.example"
  c.kyc_public_key = StubKyc.public_key

  # Ed25519 rental-token signing key (offline token).
  # Fixed dev keypair — stable vectors; swap for env-loaded PEM in production.
  c.unlock_signing_key = DevUnlockKey.private_key
end

# ─── Queries ────────────────────────────────────────────────────────────────

# scooters_available — public fleet catalog. No per-user scoping: all
# authenticated agents can browse the available fleet. The block returns the
# exact columns the agent needs (no full-table scrape). `kind` +
# `needs_licence` let the agent tell the licence-free electric scooter apart
# from the KYC-gated combustion motorcycle before it commits to a rental verb.
Kiosk::Server::Queries.register("scooters_available",
                                 description: "Browse the available fleet (scooters + motorcycles); needs_licence flags the KYC-gated combustion vehicles") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, code, status, kind, needs_licence, lat, lng, price_per_min_cents " \
    "FROM public.scooters " \
    "WHERE status = 'available' " \
    "ORDER BY id"
  ).to_a
end

# my_reservations — per-user reservation list scoped by the session GUC.
# The WHERE is provider-controlled; the agent supplies no filter. This
# demonstrates app-layer per-user isolation without RLS: the principal can
# only see rows where user_id matches kiosk.current_user_id(), enforced in
# the query definition itself.
Kiosk::Server::Queries.register("my_reservations",
                                 description: "List this principal's scooter reservations (scoped to authenticated user via kiosk.current_user_id())") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, scooter_id, status " \
    "FROM public.reservations " \
    "WHERE user_id = kiosk.current_user_id() " \
    "ORDER BY created_at DESC"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

# payment_setup — canonical skill Step 5 runs this unconditionally before
# `pay`. Mirrors the getgrocery registration shape; with StubPsp
# (no SetupIntent model) setup_required? is always false, so this is an
# immediate no-op success: {status: "ready"}.
Kiosk::Server::Actions.register("payment_setup",
  description: "Check whether the authenticated principal has a saved payment method. " \
               "Returns {status: \"ready\"} when the assistant can proceed to `pay`. " \
               "Returns {status: \"setup_required\", setup_url: \"…\"} when a hosted setup flow " \
               "must be completed by the human first. This demo's stub PSP needs no setup, " \
               "so it always returns ready. The assistant should call this before `pay`.",
  params: {}) do |_args|
  conn = ActiveRecord::Base.connection
  uid  = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  provider = Kiosk.configuration.payment_provider

  if provider.setup_required?(user_id: uid)
    { status: "setup_required", setup_url: provider.setup_url(user_id: uid) }
  else
    { status: "ready" }
  end
end

# reserve — create a scooter reservation row for the authenticated user.
#
# args: { scooter_code: <string, e.g. "SK-001"> }
# Returns: { reservation_id:, scooter_code:, price_per_min_cents: }
#
# Runs inside SessionContext (the Executor wraps `run` in a transaction with
# the four SET LOCAL GUCs already applied), so kiosk.current_user_id() is live.
Kiosk::Server::Actions.register("reserve",
                                  description: "Reserve a scooter by its code for the authenticated principal",
                                  params: { scooter_code: "string — scooter code, e.g. 'SK-001'" }) do |args|
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

# start_rental — verify gates then issue an Ed25519 rental token for the scooter lock.
#
# args: { reservation_id: }
# scooter_code is NOT accepted from the client — it is derived server-side from
# the reservation row, preventing cross-scooter unlock attacks.
# Gates (all three must pass, else 403 Forbidden):
#   1. reservation exists and belongs to the principal AND status = 'reserved'
#   2. agent is KYC-verified (kyc_verified_at NOT NULL in kiosk.agents)
#   3. principal has a settled payment (settlement) for THIS reservation
# Returns: { scooter_code:, rental_token:, exp: }
Kiosk::Server::Actions.register("start_rental",
                                  description: "Verify gates (ownership, KYC, payment) and issue an Ed25519 offline rental token",
                                  params: { reservation_id: "uuid — the reservation to activate" }) do |args|
  conn = ActiveRecord::Base.connection

  reservation_id = args[:reservation_id]

  if reservation_id.nil? || reservation_id.to_s.empty?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: reservation_id")
  end

  # ── Gate 1: reservation belongs to the principal (explicit ownership) ──
  # AND user_id = kiosk.current_user_id() added explicitly so that a
  # foreign reservation UUID returns nothing even if RLS is inactive.
  # AND status = 'reserved' so a reservation already 'active' (ride
  # in progress) is rejected here (C3 class: re-start_rental on active).
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
  # This binds the token to the ACTUAL reserved scooter, not any client value.
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
  # C2: join settlements → cart_mandates and require that line_items
  # contains the reservation_id of this specific reservation. Prevents
  # paying for reservation A and starting rental B.
  resv_filter_json = [{ reservation_id: reservation_id.to_s }].to_json
  paid = conn.execute(
    "SELECT 1 AS ok " \
    "FROM kiosk.settlements pm " \
    "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
    "WHERE pm.user_id = kiosk.current_user_id() " \
    "AND cm.line_items @> #{conn.quote(resv_filter_json)}::jsonb " \
    "LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::Forbidden.new("no settlement for this reservation") if paid.nil?

  # ── All gates passed: issue an Ed25519 rental token ─────────────────────
  # Token is bound to the server-derived scooter code, not any client value.
  # RentalTokenIssuer is a skooti-demo lib (lib/rental_token_issuer.rb), not
  # part of the neutral kiosk-server core.
  now   = Time.now.to_i
  token = RentalTokenIssuer.issue(
    scooter_code:   code,
    reservation_id: reservation_id.to_s,
    now:            now,
  )

  # Mark the reservation active.
  conn.execute(
    "UPDATE public.reservations SET status = 'active' WHERE id = #{conn.quote(reservation_id.to_s)}::uuid"
  )

  {
    scooter_code:  code,
    rental_token:  token,
    exp:           now + 900,
  }
end

# rent_motorcycle — start a rental of a COMBUSTION-ENGINE motorcycle.
#
# This is the KYC-ATTRIBUTE-GATED action that the old DefaultAgentIdp
# `unlock`-gate comment anticipated (resolves ledger K-346). Unlike the
# licence-free electric scooter (start_rental), a combustion motorcycle
# requires the calling agent to have completed a KYC attestation carrying BOTH
# named anonymized boolean attributes:
#     age_over_18 == true  AND  licence_a == true
# The provider learns only these two booleans — never the DOB or licence
# number (the anonymized/attestation privacy point). If either is missing the
# action rejects with a clean 403 `kyc_required` before doing anything else.
#
# args: { reservation_id: }  — a reservation on a needs_licence vehicle.
# Gates (all must pass, else 403):
#   0. KYC attributes: age_over_18 AND licence_a  → 403 kyc_required if unmet
#   1. reservation exists, belongs to the principal, status='reserved'
#   2. the reserved vehicle is a needs_licence motorcycle
#   3. a settled payment references THIS reservation
# On success issues the same Ed25519 offline rental token as start_rental.
Kiosk::Server::Actions.register("rent_motorcycle",
                                  description: "Rent a combustion-engine motorcycle — KYC-gated on age_over_18 AND licence_a (category-A licence); issues an Ed25519 offline rental token",
                                  params: { reservation_id: "uuid — the motorcycle reservation to activate" }) do |args|
  conn = ActiveRecord::Base.connection

  # ── Gate 0: KYC named-attribute gate (age_over_18 AND licence_a) ────────
  # Read the stored anonymized boolean attributes for the calling agent. Only
  # booleans that a valid, signed attestation granted were ever persisted — a
  # forged/self-asserted attestation never reaches this column (the /kyc
  # endpoint rejects a bad signature). A `->> 'name' = 'true'` test per
  # required attribute keeps the check in SQL and NULL-safe.
  kyc_row = conn.execute(<<~SQL).first
    SELECT
      COALESCE(kyc_attributes ->> 'age_over_18', 'false') AS age_over_18,
      COALESCE(kyc_attributes ->> 'licence_a',   'false') AS licence_a
    FROM kiosk.agents
    WHERE id = kiosk.current_agent_id()
      AND revoked_at IS NULL
  SQL
  has_all = kyc_row &&
            kyc_row["age_over_18"] == "true" &&
            kyc_row["licence_a"] == "true"
  unless has_all
    raise Kiosk::Server::Errors::KycRequired.new(
      "motorcycle rental requires KYC attributes age_over_18 and licence_a",
      hint: "complete KYC: age≥18 and category-A licence required",
    )
  end

  reservation_id = args[:reservation_id]
  if reservation_id.nil? || reservation_id.to_s.empty?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: reservation_id")
  end

  # ── Gate 1: reservation belongs to the principal, status='reserved' ────
  reservation = conn.execute(
    "SELECT id, scooter_id FROM public.reservations " \
    "WHERE id = #{conn.quote(reservation_id.to_s)}::uuid " \
    "AND user_id = kiosk.current_user_id() " \
    "AND status = 'reserved' " \
    "LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::Forbidden.new("reservation not found or not yours") if reservation.nil?

  # ── Gate 2: the reserved vehicle is a needs_licence motorcycle ──────────
  vehicle = conn.execute(
    "SELECT code, needs_licence FROM scooters WHERE id = #{conn.quote(reservation["scooter_id"].to_s)} LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::Forbidden.new("vehicle not found for reservation") if vehicle.nil?

  needs_licence = vehicle["needs_licence"] == true || vehicle["needs_licence"] == "t" || vehicle["needs_licence"] == "true"
  unless needs_licence
    raise Kiosk::Server::Errors::BadRequest.new(
      "#{vehicle["code"]} is not a licence-required motorcycle — use start_rental for licence-free vehicles",
    )
  end

  code = vehicle["code"]

  # ── Gate 3: settled payment referencing THIS reservation ────────────────
  resv_filter_json = [{ reservation_id: reservation_id.to_s }].to_json
  paid = conn.execute(
    "SELECT 1 AS ok " \
    "FROM kiosk.settlements pm " \
    "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
    "WHERE pm.user_id = kiosk.current_user_id() " \
    "AND cm.line_items @> #{conn.quote(resv_filter_json)}::jsonb " \
    "LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::Forbidden.new("no settlement for this reservation") if paid.nil?

  # ── All gates passed: issue the Ed25519 rental token ────────────────────
  now   = Time.now.to_i
  token = RentalTokenIssuer.issue(
    scooter_code:   code,
    reservation_id: reservation_id.to_s,
    now:            now,
  )

  conn.execute(
    "UPDATE public.reservations SET status = 'active' WHERE id = #{conn.quote(reservation_id.to_s)}::uuid"
  )

  {
    scooter_code:  code,
    rental_token:  token,
    exp:           now + 900,
  }
end
