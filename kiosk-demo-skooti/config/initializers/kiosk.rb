# frozen_string_literal: true

# Kiosk-demo (skooti-shape) configuration. Concrete values for the
# scooter-rental reference shape: uuid users, JWT-or-stub IdP, StubPsp,
# the prove.my broker as the trusted KYC issuer, Actions (reserve, start_rental,
# payment_setup) + named queries (scooters_available, my_reservations).

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
require Rails.root.join("lib/uuid_check")
require Rails.root.join("lib/validating_rental_provider")
require Rails.root.join("lib/prove_trust")
require Rails.root.join("lib/prove_broker_client")
require Rails.root.join("lib/dev_unlock_key")
require Rails.root.join("lib/rental_token_issuer")
require Rails.root.join("lib/pow_difficulty")

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
# the old SHA256 hashcash is gone). PoW is a metered toll, tuned per provider.
#
# Params are chosen by KIOSK_POW_DIFFICULTY (lib/pow_difficulty.rb):
#   low  (default) → n=96 k=5  — sub-second solve; CI/local stay fast.
#   high           → n=168 k=7 — genuinely memory+CPU-intensive (~10s / ~1.3 GiB)
#                    for the hosted deploy, so a poker feels the toll first-hand.
# Unset = low, so this demo's flows and CI register at the fast params.
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
SKOOTI_REGISTRATION_POW_PARAMS = PowDifficulty.params

# ── PoW HMAC secret — REQUIRED outside development/test (K-541) ────────────
# pow_secret is the HMAC key the engine signs every PoW challenge with. This
# repo is PUBLIC, so a shipped fallback would be world-readable: a reader could
# mint a self-signed challenge at trivial difficulty {n:8,k:1} and forge a proof
# the server accepts — silently turning proof-of-work OFF. It MUST come from the
# environment in production and fail LOUD when absent, matching KIOSK_ISSUER and
# the signing key. Dev/test keep a stable (non-secret) default so `bin/rails s`,
# the demo drivers and e2e boot out of the box; a too-short secret is rejected.
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
  "skooti-demo-pow-secret-dev-insecure-default"
end
raise "KIOSK_POW_SECRET must be at least 32 bytes (got #{pow_secret.bytesize}) — generate one with `openssl rand -hex 32`." if pow_secret.bytesize < 32

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in this demo). Set app_role to the same role so the
  # `GRANT TO app_role` statements in `enable_rls_on` are no-ops on a
  # role that already has all privileges via ownership.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  # ── Issuer origin — REQUIRED outside development/test (K-510) ────────────
  # `issuer` is this operator's canonical origin, and it is load-bearing three
  # times over: it is advertised in /.well-known/kiosk.json, it is the `iss` of
  # every JWT this app mints, and PopVerifier enforces it as the `aud` of every
  # assistant proof. A deployment that silently fell back to localhost would
  # boot HAPPILY and then reject every assistant that dialed the real host with
  # "proof audience mismatch" — a total, silent auth outage from one unset
  # variable, whose error text points the agent at an origin it never visited.
  # So it fails LOUD at boot, matching the signing key (kiosk-server's
  # default_signing_key raises when KIOSK_SIGNING_KEY_PEM/_B64 is absent).
  # Development and test keep a localhost default so `bin/rails s` and the demo
  # flows run out of the box; the port follows the one the server actually
  # binds (PORT, the same variable lib/tasks/demo.rake and `rails s` read).
  c.issuer = ENV.fetch("KIOSK_ISSUER") do
    unless Rails.env.local?
      raise <<~MSG
        KIOSK_ISSUER is required outside development/test.

        It is this operator's canonical origin: advertised in
        /.well-known/kiosk.json, minted as the `iss` of every Kiosk JWT, and
        enforced as the `aud` of every assistant proof-of-possession. Falling
        back to localhost here would reject EVERY assistant with "proof
        audience mismatch".

        Set it to the origin agents actually dial:
          KIOSK_ISSUER=https://skooti.demo.kiosk.tech
      MSG
    end

    "http://localhost:#{ENV.fetch("PORT", "3004")}"
  end

  # UNIFORM-VALIDATION slice-1 (K-479): validate a PRESENT `pow` field against
  # the normative PoW schema at the wire choke point, so a malformed pow gets a
  # clear 400 bad_request (with a shape hint) instead of a silent re-issued 402
  # loop. Needs the json_schemer gem (in the Gemfile). Absent/valid pow paths
  # unchanged.
  c.validate_requests = true
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. When
  # KIOSK_POW_DIFFICULTY=high, surface an honest "beware: intensive PoW" notice
  # here so an agent/reader sees the toll BEFORE it dials register (the 402
  # challenge params say the same, this is the up-front discovery signal).
  c.owner  = { name: "skooti", support: "help@skooti.app" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.10.md"
  c.skill_sha256 = "67265bd147ea3c6c32b240b1f2fc17f57ba17342770b989270ce34eb3f302a91"

  # JwtOrStubIdp tries Kiosk-issued JWTs (kiosk-pop register/login output;
  # OAuth device-grant dormant) first,
  # then falls back to StubIdp's bespoke `agent:u-…:a-…:r-…` shape.
  c.agent_idp = JwtOrStubIdp.new(stub: Rails.env.local? ? StubIdp.new : nil)
  # The web-session channel for the account-binding surfaces (verify
  # page, link mint, unlink) — see lib/stub_user_idp.rb for the scope.
  # DEV/TEST ONLY (K-555): the stub parses an UNSIGNED, self-asserted
  # `user:u-<uuid>` bearer into a human identity, so it is wired only under
  # Rails.env.local?; in production user_idp is nil and the binding surfaces
  # 401 until a real adapter (kiosk-user-idp-devise) is configured.
  c.user_idp = Rails.env.local? ? StubUserIdp.new : nil

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

  # KYC attestation verifier — trusts the prove.my broker (the shared
  # anonymizing KYC issuer). skooti no longer hosts its own issuer: it configures
  # prove.my as its kyc_issuer + kyc_public_key ONCE (design §5.3) and asks the
  # broker for exactly the claims it needs (age_over_18 + licence_a). The trust
  # anchors come from ProveTrust (env-overridable by the two-server harness,
  # pinned dev fallback for plain boot). No new framework surface — the same two
  # config attributes the shipped KycVerifier already reads.
  c.kyc_issuer    = ProveTrust.issuer
  c.kyc_public_key = ProveTrust.public_key
  # OPERATOR-BINDING (aud): the engine KycVerifier now REJECTS at the wire any
  # attestation whose `aud` != this operator's kyc_audience — so a claim the
  # broker minted for another operator cannot unlock skooti even before skooti's
  # callback-layer operator check runs. skooti declares its stable broker handle
  # ("skooti") as the audience (the broker mints `aud` = the audience skooti sends
  # at intake), not its per-deploy origin URL, so the value is stable across the
  # 127.0.0.1 / skooti.app harness ports.
  c.kyc_audience  = ProveTrust.operator_id

  # Ed25519 rental-token signing key (offline token).
  # Fixed dev keypair — stable vectors; swap for env-loaded PEM in production.
  c.unlock_signing_key = DevUnlockKey.private_key
end

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  require Rails.root.join("lib/demo_telemetry")
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

# ─── Queries ────────────────────────────────────────────────────────────────

# scooters_available — public fleet catalog. No per-user scoping: all
# authenticated agents can browse the available fleet. The block returns the
# exact columns the agent needs (no full-table scrape): each vehicle's `name`
# and pickup `dock`/location so a plain prompt ("rent an electric scooter near
# the Jordaan", "rent the Amstel Cruiser motorcycle") resolves to a concrete
# row, plus `kind` + `needs_licence` so the agent tells the licence-free
# electric scooter apart from the KYC-gated combustion motorcycle before it
# commits to a rental verb, and the EUR per-minute rate it must sign its cart at.
Kiosk::Server::Queries.register("scooters_available",
                                 description: "Browse the available fleet — each row carries the vehicle's name and pickup dock/location " \
                                              "so you can pick one by name or nearest dock. needs_licence flags the KYC-gated combustion " \
                                              "motorcycle (rent it via rent_motorcycle); licence-free scooters use start_rental. " \
                                              "price_per_min_cents is EUR cents per minute — carts must be signed in eur at the operator-quoted total. " \
                                              "Takes no parameters and returns the whole available fleet (small; not paginated); reference a " \
                                              "vehicle by its `code` (e.g. \"SK-001\") when reserving.",
                                 params: {},
                                 input_schema: {
                                   type: "object",
                                   additionalProperties: false,
                                   properties: {},
                                   required: [],
                                 },
                                 example_params: {},
                                 example_row: {
                                   code: "SK-001", name: "Jordaan Jet", dock: "Jordaan Dock",
                                   status: "available", kind: "scooter", needs_licence: false,
                                   lat: 52.3739, lng: 4.8809, price_per_min_cents: 15, currency: "eur",
                                 }) do |_params|
  # `code` is the ONLY vehicle handle on the wire — reserve takes scooter_code.
  # The numeric primary key is deliberately NOT selected: a row id no verb
  # accepts is a dead field that invites the assistant to guess it is some
  # verb's param (K-516, and K-484 for the same defect on atablefor;
  # descriptor-house-style.md "Never expose a row id that no verb consumes").
  # It still orders the fleet — ORDER BY needs no SELECT.
  rows = ActiveRecord::Base.connection.execute(
    "SELECT code, name, dock, status, kind, needs_licence, lat, lng, price_per_min_cents " \
    "FROM public.scooters " \
    "WHERE status = 'available' " \
    "ORDER BY id"
  ).to_a
  # Advertise the pricing currency so an external assistant knows to sign its
  # cart in EUR (the cashier check rejects any other currency at capture).
  rows.each { |r| r["currency"] = "eur" }
  rows
end

# my_reservations — per-user reservation list scoped by the session GUC.
# The WHERE is provider-controlled; the agent supplies no filter. This
# demonstrates app-layer per-user isolation without RLS: the principal can
# only see rows where user_id matches kiosk.current_user_id(), enforced in
# the query definition itself.
Kiosk::Server::Queries.register("my_reservations",
                                 description: "List this principal's scooter reservations (scoped to authenticated user via kiosk.current_user_id()). Each row carries a `reservation_id`; pass it to start_rental / rent_motorcycle as `reservation_id`. Each row also carries the vehicle's `scooter_code` — the same handle scooters_available shows and reserve takes.") do |_params|
  # The vehicle is identified by its `code`, never by the numeric scooters.id:
  # that primary key is not a param of any verb, so emitting it would be a dead
  # field the assistant can only guess at (K-516 sweep; house-style "never
  # expose a row id that no verb consumes"). The join turns the dead internal
  # key into the live handle instead of dropping the vehicle from the row.
  ActiveRecord::Base.connection.execute(
    "SELECT r.id AS reservation_id, s.code AS scooter_code, r.status " \
    "FROM public.reservations r " \
    "JOIN public.scooters s ON s.id = r.scooter_id " \
    "WHERE r.user_id = kiosk.current_user_id() " \
    "ORDER BY r.created_at DESC"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

# payment_setup — canonical skill Step 5 runs this unconditionally before
# `pay`. Mirrors the getgrocery registration shape; with StubPsp
# (no SetupIntent model) setup_required? is always false, so this is an
# immediate no-op success: {status: "ready"}.
#
# POLL CADENCE + STOP CONDITION (K-477/K-595): the wire has no server→assistant
# push, so an assistant that ever DOES get a `setup_required` learns the human
# finished the hosted card entry ONLY by re-calling this. The descriptor
# therefore has to state a cadence AND a terminal stop condition — without one an
# agent invents its own and can poll forever if the human never completes the
# step. Stated even though this demo's StubPsp short-circuits it, so the
# PUBLISHED contract is the same across all three payment demos.
#
# The cadence here is the skill's, verbatim (skill.md Step 5: ~5 s for the first
# minute, then ~15 s, give up after ~5 minutes) — the skill is what assistants
# actually follow, so a descriptor that prescribes anything else is a second,
# losing instruction. And no CHECK COUNT is stated: a count is derived from the
# cadence and the horizon, so it silently goes wrong the moment either moves
# (the earlier "~60 checks" implied a flat 5 s cadence and was more than double
# what this schedule yields). The horizon is the number an assistant needs.
#
# NOTE getgrocery's descriptor also promises the setup_url is stable across polls
# (K-492 — a real-Stripe SetupIntent-reuse property). That promise is NOT
# repeated here: StubPsp mints no setup session at all, so there is nothing to be
# stable about and claiming it would be a claim about code this demo never runs.
Kiosk::Server::Actions.register("payment_setup",
  description: "Check whether the authenticated principal has a saved payment method. " \
               "Returns {status: \"ready\"} when the assistant can proceed to `pay`. " \
               "Returns {status: \"setup_required\", setup_url: \"…\"} when a hosted setup flow " \
               "must be completed by the human first — hand the setup_url to the human, wait for " \
               "them to finish, then call payment_setup again before paying. " \
               "This demo's stub PSP needs no setup, so it always returns ready. " \
               "The assistant should call this before `pay`. " \
               "POLLING: if you ever do get setup_required, re-check every ~5 seconds for the first " \
               "minute, then every ~15 seconds, while your human is at the hosted page, and GIVE UP " \
               "after about 5 minutes — tell your human the card setup is still not finished rather " \
               "than polling indefinitely; they can finish later and you re-check then.",
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
                                  description: "Reserve a scooter by its code for the authenticated principal. " \
                                               "To pay, sign your AP2 cart mandate in EUR at the quoted total (price_per_min_cents for the " \
                                               "upfront minute) with a line_item that references the returned reservation_id; the operator " \
                                               "verifies currency and total against its quote before charging (the result carries a pay_hint)",
                                  params: { scooter_code: "string — scooter code, e.g. 'SK-001'" },
                                  input_schema: {
                                    type: "object",
                                    additionalProperties: false,
                                    properties: {
                                      scooter_code: { type: "string",
                                                      description: "Vehicle code from a scooters_available row, e.g. \"SK-001\"." },
                                    },
                                    required: ["scooter_code"],
                                  },
                                  example_params: { scooter_code: "SK-001" },
                                  example_row: {
                                    reservation_id: "a3f9c1e2-7b4d-4e8a-9c1f-2d6e5b0a3c7f",
                                    scooter_code: "SK-001", price_per_min_cents: 15, currency: "eur",
                                    pay_hint: "pay in EUR with a cart mandate whose total_amount_cents == 15 …",
                                  }) do |args|
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

  quoted_total = scooter["price_per_min_cents"].to_i
  {
    reservation_id:      reservation["id"],
    scooter_code:        scooter["code"],
    price_per_min_cents: scooter["price_per_min_cents"],
    currency:            "eur",
    pay_hint:            "pay in EUR with a cart mandate whose total_amount_cents == #{quoted_total} " \
                         "(the quoted upfront minute) and whose line_items reference this reservation: " \
                         "one {\"sku\", \"qty\": 1, \"price_cents\": #{quoted_total}, " \
                         "\"reservation_id\": \"#{reservation["id"]}\"} entry — the operator verifies " \
                         "currency and total against its quote before charging",
  }
end

# start_rental — verify gates then issue an Ed25519 rental token for the scooter lock.
#
# args: { reservation_id: }
# scooter_code is NOT accepted from the client — it is derived server-side from
# the reservation row, preventing cross-scooter unlock attacks.
# Gates (both must pass, else 403 Forbidden):
#   1. reservation exists and belongs to the principal AND status = 'reserved'
#   2. principal has a settled payment (settlement) for THIS reservation
# Licence-free scooters need NO KYC (K-442, DECISIONS-LOG KYC-MODEL) — only the
# combustion motorcycle (rent_motorcycle) is KYC-gated. "Ride even if you can't
# walk yet, just pay the fare."
# Returns: { scooter_code:, rental_token:, exp: }
Kiosk::Server::Actions.register("start_rental",
                                  description: "Verify gates (ownership, payment) and issue an Ed25519 offline rental token for a licence-free scooter (no KYC)",
                                  params: { reservation_id: "uuid — the reservation to activate" }) do |args|
  conn = ActiveRecord::Base.connection

  reservation_id = args[:reservation_id]

  if reservation_id.nil? || reservation_id.to_s.empty?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: reservation_id")
  end
  # K-581/K-582: this id is cast `::uuid` below — a malformed one made Postgres
  # raise InvalidTextRepresentation, which is not a Kiosk error and so surfaced
  # as a raw 500 (leaking "invalid input syntax for type uuid") for what is
  # plainly a client mistake. Check the shape first, answer 400.
  unless UuidCheck.valid?(reservation_id)
    raise Kiosk::Server::Errors::BadRequest.new(
      "reservation_id #{reservation_id.to_s.inspect} is not a uuid — pass the `reservation_id` " \
      "that reserve returned (also listed by my_reservations)"
    )
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

  # ── Gate 2: settled payment whose cart references THIS reservation ───────
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
# `unlock`-gate comment anticipated. Unlike the
# licence-free electric scooter (start_rental), a combustion motorcycle
# requires the calling agent to have completed a KYC attestation carrying BOTH
# named anonymized boolean attributes:
#     age_over_18 == true  AND  licence_a == true
# The provider learns only these two booleans — never the DOB or licence
# number (the anonymized/attestation privacy point). If either is missing the
# action rejects with a clean 403 `kyc_required` before doing anything else.
#
# HONEST SCOPE (KYC-DEMO-SCOPE): this is an ELIGIBILITY gate — it proves a valid
# licence + 18+ *exist* behind the assistant — NOT an accountability mechanism.
# An anonymized claim is transferable (a licensed friend could vouch) and the
# demo settles a nameless hold, not a deposit, so nobody is on the hook for the
# actual rental. Real vehicle rental needs identity + a contract + insurance +
# a deposit on top (not modeled). This case illustrates the attestation
# MECHANISM; anonymized minimal KYC's clean home is a low-liability age-gated
# PURCHASE (see the getgrocery alcohol demo), where the transaction just closes.
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
      # Point an external agent at the completable path: `run request_kyc`
      # returns a verification_url the human approves, then poll `query
      # kyc_status` for the signed attestation and submit it to
      # POST /kiosk/agents/kyc — no pre-shared issuer key needed (K-440/K-443).
      hint: "call `run request_kyc` to start age≥18 + category-A licence verification: " \
            "it returns a verification_url for the human to approve; then poll " \
            "`query kyc_status` for the signed attestation and submit it to " \
            "POST /kiosk/agents/kyc, then retry rent_motorcycle",
    )
  end

  reservation_id = args[:reservation_id]
  if reservation_id.nil? || reservation_id.to_s.empty?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: reservation_id")
  end
  # K-581/K-582: cast `::uuid` below — reject a malformed id as a clean 400, not
  # a 500 that leaks the PG error text.
  unless UuidCheck.valid?(reservation_id)
    raise Kiosk::Server::Errors::BadRequest.new(
      "reservation_id #{reservation_id.to_s.inspect} is not a uuid — pass the `reservation_id` " \
      "that reserve returned (also listed by my_reservations)"
    )
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

# request_kyc — start a verification at the prove.my broker an EXTERNAL agent can
# COMPLETE without any pre-shared issuer key (K-440/K-443, design §5.1).
#
# Rewired to the shared broker: instead of minting a LOCAL stub token, skooti
# calls prove.my's intake (server-to-server) with its own callback_url, the two
# claims it needs (age_over_18 + licence_category:A), and the agent's user_id as
# the subject the claim must bind to. The broker returns an unguessable
# verification_url (on the BROKER) and a request_id; skooti stores that
# request_id as this row's request_token (+ the broker's nonce for callback
# anti-replay) and returns the broker's verification_url for the agent to relay
# to its human. On approve, the BROKER signs an anonymized {age_over_18,
# licence_a} claim and POSTs it to skooti's POST /kyc/callback; the agent then
# polls `query kyc_status` and submits the returned jws to POST /kiosk/agents/kyc
# (agent contract UNCHANGED — only the issuer behind the link changed).
#
# args: {} — none; the caller is identified by its token.
# Returns: { request_id:, verification_url:, status: "pending" }
Kiosk::Server::Actions.register("request_kyc",
                                 description: "Start age≥18 + category-A driving-licence verification for the authenticated principal. " \
                                              "Returns a verification_url to relay to your human to approve (an anonymizing KYC broker confirms " \
                                              "the facts and signs them — it never shares the documents) and a request_id. After the human " \
                                              "approves, poll `query kyc_status` with the request_id for the signed attestation, submit it " \
                                              "to POST /kiosk/agents/kyc, then retry rent_motorcycle. No pre-shared issuer key needed.",
                                 params: {}) do |_args|
  conn = ActiveRecord::Base.connection

  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?

  # Call the broker's intake server-to-server. skooti hands the broker its own
  # callback URL, the claims it needs, and the agent's user_id (the subject the
  # signed claim must bind to). The broker mints the unguessable request_id +
  # verification_url on ITS side.
  callback_base = Kiosk.configuration.issuer.to_s.chomp("/")
  broker = ProveBrokerClient.start_verification(
    callback_url:     "#{callback_base}/kyc/callback",
    requested_claims: %w[age_over_18 licence_category:A],
    subject_handle:   uid.to_s,
  )

  request_id       = broker.fetch("request_id")
  verification_url = broker.fetch("verification_url")
  nonce            = broker["nonce"].to_s

  # Store the BROKER's request_id as our local request_token so kyc_status
  # (unchanged) polls it, plus the broker nonce the callback must echo.
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

# kyc_status — poll a request_kyc verification the authenticated agent opened
# (K-440/K-443). Scoped to kiosk.current_user_id(): an agent can only read its
# OWN request, so it cannot poll (or lift the jws from) another agent's request.
#
# args: { request_id: <token from request_kyc> }
# Returns one row:
#   { status: "pending" }                         while the human has not acted
#   { status: "approved", kyc_jws: "<compact JWS>" } once approved — submit the
#     kyc_jws to POST /kiosk/agents/kyc, then retry rent_motorcycle
#   { status: "declined" }                        if the human declined
Kiosk::Server::Queries.register("kyc_status",
                                 description: "Poll a request_kyc verification by its request_id. Returns {status: \"pending\"} until the " \
                                              "human acts; {status: \"approved\", kyc_jws} once approved (submit the kyc_jws to " \
                                              "POST /kiosk/agents/kyc, then retry rent_motorcycle); {status: \"declined\"} if declined.",
                                 params: { request_id: "string — the request_id returned by request_kyc" }) do |params|
  request_id = params[:request_id]
  if request_id.nil? || request_id.to_s.empty?
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
