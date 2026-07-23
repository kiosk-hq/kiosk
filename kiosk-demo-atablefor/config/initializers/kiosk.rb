# frozen_string_literal: true

# Kiosk-demo (atablefor-shape) configuration. Concrete values for the
# restaurant table-booking reference shape: uuid users, JWT-or-stub IdP,
# NO payment provider (a reservation takes no money), Actions
# (book_table, cancel_booking).

# ── Ephemeral dev signing key ─────────────────────────────────────────────
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
require Rails.root.join("lib/pow_difficulty")
require "kiosk/user_identity_providers/devise"

# ── PoW / Reputation (R2) — activated only when KIOSK_POW_DEMO=1 ──────────
#
# Gate: the Equihash PoW challenge is issued ONLY for the :query verb.
# The :run verb is left ungated so the existing no-human booking flow
# (book_flow.rb / rake demo:book) continues to pass without any PoW handling.
#
# The guard is intentional:
#   - rake demo:book boots the server WITHOUT KIOSK_POW_DEMO=1 → no PoW.
#   - rake demo:pow  boots the server WITH   KIOSK_POW_DEMO=1 → PoW active.
#
# Reservation-scalping is exactly the abuse a table-booking provider fears:
# scripts that mass-claim prime-time 2-tops to resell. PoW prices that at the
# door — a metered toll per query, tuned per provider, not a hardware wall.
#
# Equihash params are chosen by KIOSK_POW_DIFFICULTY (lib/pow_difficulty.rb):
#   low  (default) → n=96 k=5  — small, non-toy instance the reference solver
#                    clears in well under a second; local flows + CI stay fast.
#   high           → n=168 k=7 — the shipped default (~10s / ~1.3 GiB): a real
#                    memory+CPU toll for the hosted deploy so a scalper feels
#                    the anti-scalping cost first-hand. Unset = low.
# Both the :query toll (KIOSK_POW_DEMO) and the anti-scalping reputation gate
# (KIOSK_POW_REPUTATION_DEMO) inherit this level.
#
# atablefor is INTENTIONALLY the ONE demo pinned to high in the hosted deploy
# (deploy/env/atablefor.env.example ships KIOSK_POW_DIFFICULTY=high). It is the
# designated production-grade showcase: a poker/scalper feels the real ~9–10 s /
# ~1.3 GiB anti-reservation-scalping toll first-hand (see the "beware" banner on
# the demo root page). Every other demo is knob-adjustable but defaults light so
# CI and quick poking stay fast; unset here still resolves to low.
EQUIHASH_DEMO_PARAMS = PowDifficulty.params

if ENV["KIOSK_POW_DEMO"] == "1"
  require "kiosk/pow/equihash"
  require "kiosk/reputation"

  Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

  # Demo policy: always challenge :query (availability lookup); let :run through
  # freely. A real provider replaces this with Policies::RateAndReputation or a
  # domain-specific subclass. The inline class keeps the demo self-contained.
  class AtableforDemoPowPolicy < Kiosk::Reputation::Policy
    def initialize(pow_params)
      @pow_params = pow_params
    end

    # @return [{alg:, params:}] when verb is :query; nil otherwise.
    def challenge_for(identity:, verb:, factors:)
      return nil unless verb == :query

      { alg: Kiosk::Pow::Equihash::NAME, params: @pow_params }
    end
  end

  # Counter file written by on_bad_proof; the pow_flow.rb driver reads it.
  ATABLEFOR_BAD_PROOF_FILE = "/tmp/kiosk-atablefor-bad-proof.count"
  File.write(ATABLEFOR_BAD_PROOF_FILE, "0")
end

# ── Reputation PoW gate (anti-scalping) — activated only when KIOSK_POW_REPUTATION_DEMO=1 ──
#
# The anti-scalping mechanic: a fresh / low-reputation agent pays ESCALATING
# PoW (N×PoW) to look at prime-time availability, and that cost DROPS as it
# builds a real booking history. A scalper renting fresh identities pays and
# pays; a returning diner earns relief. Escalation is by PROOF COUNT:
#   0 confirmed bookings → count = base_count(1) + unproven_count_bonus(1) = 2 proofs
#   1 confirmed booking  → count = base_count(1) = 1 proof (a real booking earns relief)
#   2+ confirmed bookings → free pass (proven?(bookings) → challenge_for returns nil)
#
# The factors callable performs a REAL DB lookup: COUNT(*) of the principal's
# CONFIRMED bookings — no faking. Mapped into the shipped RateAndReputation
# policy's `settled_purchases_count` factor (a generic "proven completed
# actions" count; for a booking provider that is confirmed reservations).
# Equihash params are the small demo instance so each proof solves sub-second.

if ENV["KIOSK_POW_REPUTATION_DEMO"] == "1"
  require "kiosk/pow/equihash"
  require "kiosk/reputation"

  Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

  ATABLEFOR_REPUTATION_BAD_PROOF_FILE = "/tmp/kiosk-atablefor-reputation-bad-proof.count"
  File.write(ATABLEFOR_REPUTATION_BAD_PROOF_FILE, "0")
end

# ── COUNT-BASED PoW backoff (POW-RECENCY-GRACE) — activated when KIOSK_POW_BACKOFF_DEMO=<N>, N = free-call count ──
#
# The "solve once, next N calls free" mechanic: an AI assistant solves ONE
# Equihash proof and is then granted a fixed COUNT of ungated follow-up requests
# before being re-challenged. A COUNT (not a time window) is deliberate — a
# window would let a bot flood thousands of requests inside it; a count caps
# exactly how many free calls one ~9 s solve buys. This makes the otherwise-heavy
# atablefor PoW toll pokeable: one solve buys a short burst of free calls, then
# the toll returns. Uses the shipped Kiosk::Reputation::Policies::Backoff with a
# fresh in-process BackoffStore — a MULTI-WORKER deploy needs a shared store or
# the grant is only per-worker (see BackoffStore's doc + atablefor.env.example).
if ENV["KIOSK_POW_BACKOFF_DEMO"].to_i > 0
  require "kiosk/pow/equihash"
  require "kiosk/reputation"

  Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
end

# Inject the RLS DSL into ActiveRecord::Migration so migrations can call
# `enable_rls_on TABLE do ... end` directly. atablefor keeps kiosk-rls wired as
# the baseline data plane (all 7 demos do); it simply ships no RLS *showcase*
# task — booking has no apt RLS beat. The kiosk-rls README documents this opt-in.
ActiveRecord::Migration.include(Kiosk::RLS::DSL)

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # The Rails connection's role owns the tables AND issues queries (no
  # role separation in v0.1 alpha). This demo runs WITHOUT RLS enforcement —
  # isolation is enforced at the app layer (the book_table Action's explicit
  # user_id scoping and the my_bookings query's own WHERE predicate) — so
  # app_role and system_role are set to the same role only to satisfy the
  # config; no enable_rls_on / GRANT statements run here.
  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3002")
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  # owner is free-form and flows verbatim into /.well-known/kiosk.json. When
  # KIOSK_POW_DIFFICULTY=high, surface an honest "beware: intensive PoW" notice
  # here so an agent/reader sees the anti-scalping toll up front (the 402
  # challenge params carry the same heavy n/k).
  c.owner  = { name: "atablefor", support: "help@atablefor.app" }
  if (notice = PowDifficulty.pow_notice)
    c.owner = c.owner.merge(pow_difficulty: PowDifficulty.level, pow_notice: notice)
  end
  # Dual-check (skill.md): canonical skill URL + SHA-256 of its content.
  c.skill_url    = "https://kiosk.tech/skill-v0.3.4.md"
  c.skill_sha256 = "624b21555d46c6e570b766b18cd15a553768f4de9f41911ae6d8e500cf9706f2"

  # JwtOrStubIdp tries Kiosk-issued JWTs (kiosk-pop register/login output;
  # OAuth device-grant dormant) first, then falls back to StubIdp's bespoke
  # `agent:u-…:a-…:r-…` shape. One endpoint authenticates both for the demo.
  # Real providers swap in `kiosk-user-idp-devise` (or another adapter).
  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)
  # The provider's own web-session channel (Devise/Warden): authenticates the
  # signed-in human diner on the account-binding surfaces — the link-code mint,
  # the device verify page, and unlink. A diner mints a link code here and their
  # assistant redeems it, binding the assistant to the diner's account. Walked
  # by `rake demo:binding`.
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new

  # ── NO payment_provider ──────────────────────────────────────────────────
  # This is deliberate and load-bearing: with no AP2 provider configured,
  # `pay` drops out of `capabilities` and the discovery documents carry no
  # payments block. atablefor books restaurant tables — a reservation takes
  # no money. The advertised capabilities are [schema, query, run].

  # ── Equihash PoW gate (active only when KIOSK_POW_DEMO=1) ───────────────
  if ENV["KIOSK_POW_DEMO"] == "1"
    # Small, non-toy Equihash instance for demo speed (sub-second solve).
    pow_params = Kiosk::Pow::Equihash.params(**EQUIHASH_DEMO_PARAMS)

    c.reputation_policy = AtableforDemoPowPolicy.new(pow_params)
    c.pow_secret        = ENV.fetch("KIOSK_POW_SECRET", "demo-pow-secret")
    c.pow_ttl           = 300

    # Factors: always return empty (the demo policy ignores factors and
    # challenges :query unconditionally). A real provider wires DB lookups.
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }

    # on_bad_proof: increment the counter file so pow_flow.rb can assert it.
    c.on_bad_proof = ->(identity:) {
      count = (File.read(ATABLEFOR_BAD_PROOF_FILE).to_i rescue 0)
      File.write(ATABLEFOR_BAD_PROOF_FILE, (count + 1).to_s)
    }
  end

  # ── Reputation PoW gate (active only when KIOSK_POW_REPUTATION_DEMO=1) ────
  # Uses the shipped RateAndReputation policy with REAL confirmed-booking-count
  # factors, escalating by PROOF COUNT (N×PoW):
  #   proven_purchases_threshold: 2  → 2 confirmed bookings → free pass
  #   base_count: 1, unproven_count_bonus: 1 → 0 bookings: 2 proofs;
  #                                            1 booking: 1 proof; 2+: nil
  if ENV["KIOSK_POW_REPUTATION_DEMO"] == "1"
    c.reputation_policy = Kiosk::Reputation::Policies::RateAndReputation.new(
      proven_purchases_threshold: 2,
      low_rate_threshold:         100,
      base_count:                 1,
      count_min:                  1,
      count_max:                  10,
      rate_count_step:            1,
      rate_step:                  10,
      unproven_count_bonus:       1,
      bad_proof_count_factor:     3,
      equihash_n:                 EQUIHASH_DEMO_PARAMS[:n],
      equihash_k:                 EQUIHASH_DEMO_PARAMS[:k],
    )
    c.pow_secret = ENV.fetch("KIOSK_POW_SECRET", "demo-pow-secret")
    c.pow_ttl    = 300

    # Factors: real DB lookup — COUNT(*) of the principal's CONFIRMED bookings.
    # A confirmed reservation is this provider's "proven completed action"
    # signal, mapped into the policy's settled_purchases_count factor.
    # request_rate_per_min and bad_proof_count are fixed at 0 for the demo.
    c.reputation_factors = ->(identity:, **) {
      uid  = identity.user_id
      conn = ActiveRecord::Base.connection
      count = conn.execute(
        "SELECT COUNT(*) AS confirmed_count FROM bookings " \
        "WHERE user_id = #{conn.quote(uid.to_s)}::uuid AND status = 'confirmed'"
      ).first["confirmed_count"].to_i
      Kiosk::Reputation::Factors.new(
        kyc_level:               nil,
        settled_purchases_count: count,
        settled_purchases_cents: nil,
        request_rate_per_min:    0,
        account_age_seconds:     nil,
        dispute_count:           nil,
        bad_proof_count:         0,
      )
    }

    c.on_bad_proof = ->(identity:) {
      cnt = (File.read(ATABLEFOR_REPUTATION_BAD_PROOF_FILE).to_i rescue 0)
      File.write(ATABLEFOR_REPUTATION_BAD_PROOF_FILE, (cnt + 1).to_s)
    }
  end

  # ── COUNT-BASED PoW backoff gate (active only when KIOSK_POW_BACKOFF_DEMO=1) ─
  # "Solve once, next N calls free": one solved proof grants the assistant
  # `count` ungated follow-up calls, then it is re-challenged. count:3 keeps the
  # demo fast; base demands ONE fresh Equihash proof (the small demo instance so
  # a solve is sub-second at KIOSK_POW_DIFFICULTY=low). The in-process
  # BackoffStore is authoritative per worker — a multi-worker deploy needs a
  # shared store (see BackoffStore's cross-worker caveat).
  if ENV["KIOSK_POW_BACKOFF_DEMO"].to_i > 0
    c.reputation_policy = Kiosk::Reputation::Policies::Backoff.new(
      # The env value IS the count: KIOSK_POW_BACKOFF_DEMO=10 grants 10 ungated
      # calls per solve. Any positive integer enables; unset/0 leaves the toll
      # per-request. (demo:backoff sets 3; the deploy env ships 10.)
      count: [ENV["KIOSK_POW_BACKOFF_DEMO"].to_i, 1].max,
      base:  {
        alg:    Kiosk::Pow::Equihash::NAME,
        params: Kiosk::Pow::Equihash.params(**EQUIHASH_DEMO_PARAMS),
        count:  1,
      },
    )
    c.pow_secret = ENV.fetch("KIOSK_POW_SECRET", "demo-pow-secret")
    c.pow_ttl    = 300

    # The Backoff strategy ignores factors, but the gate still gathers them
    # (config.reputation_factors is called before challenge_for). Return empty.
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }
  end
end

# ── Live-activity telemetry — opt-in, app-layer, privacy-safe ───
# Off unless KIOSK_TELEMETRY=1. One event per successful wire action via a Rack
# middleware; aggregate at GET /demo/activity.json. NOT in kiosk-core.
if ENV["KIOSK_TELEMETRY"] == "1"
  require Rails.root.join("lib/demo_telemetry")
  ATABLEFOR_VERB_MAP = {
    "book_table"     => "booked",
    "cancel_booking" => "cancelled",
  }.freeze
  Rails.application.config.middleware.use(
    DemoTelemetryMiddleware, verb_map: ATABLEFOR_VERB_MAP,
  )
end

# ─── Queries ────────────────────────────────────────────────────────────────

# availability — open table-slots for a given date that seat the party.
# Public (no per-user scoping): any authenticated agent may browse availability.
# The agent supplies :date (ISO 8601 date) and :party_size; the block builds
# the query with conn.quote binding — agent input is data, never SQL. Returns
# only slots whose status is 'open' and whose capacity >= party_size.
Kiosk::Server::Queries.register("availability",
                                 description: "List open table time-slots for a date that seat the party " \
                                              "(params: date, party_size)",
                                 params: {
                                   date:       "string — the reservation date as an ISO 8601 date (YYYY-MM-DD)",
                                   party_size: "integer — number of guests; only tables seating at least this many are returned",
                                 }) do |params|
  date       = params.fetch(:date) { raise Kiosk::Server::Errors::BadRequest.new("missing param: date") }
  party_size = (params.fetch(:party_size) { raise Kiosk::Server::Errors::BadRequest.new("missing param: party_size") }).to_i
  conn = ActiveRecord::Base.connection
  conn.execute(
    "SELECT ts.id, ts.table_label, ts.capacity, " \
    "to_char(ts.slot_date, 'YYYY-MM-DD') AS slot_date, " \
    "to_char(ts.slot_time, 'HH24:MI')    AS slot_time " \
    "FROM table_slots ts " \
    "WHERE ts.status = 'open' " \
    "AND ts.slot_date = #{conn.quote(date.to_s)}::date " \
    "AND ts.capacity >= #{party_size} " \
    "ORDER BY ts.slot_time, ts.capacity"
  ).to_a
end

# my_bookings — per-user booking list scoped by the session GUC.
# The WHERE is provider-controlled; the agent supplies no filter. This
# demonstrates app-layer per-user isolation: the principal can only see rows
# where user_id matches kiosk.current_user_id(), enforced in the query itself.
Kiosk::Server::Queries.register("my_bookings",
                                 description: "List this principal's table bookings (scoped to authenticated user via kiosk.current_user_id())") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT b.id, b.restaurant_id, b.table_slot_id, b.party_size, b.status, " \
    "to_char(ts.slot_date, 'YYYY-MM-DD') AS slot_date, " \
    "to_char(ts.slot_time, 'HH24:MI')    AS slot_time " \
    "FROM bookings b " \
    "JOIN table_slots ts ON ts.id = b.table_slot_id " \
    "WHERE b.user_id = kiosk.current_user_id() " \
    "ORDER BY ts.slot_date, ts.slot_time"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

# book_table — claim an open table-slot for the authenticated principal and
# create a confirmed booking. Selects an open slot at Mamma Pizza matching the
# requested date, time and party size, atomically marks it 'booked', and
# records the booking under kiosk.current_user_id(). No payment — a reservation
# takes no money.
Kiosk::Server::Actions.register("book_table",
                                  description: "Book a restaurant table for the authenticated principal " \
                                               "(params: date, time, party_size). Confirms a reservation on an " \
                                               "open slot that seats the party; returns the confirmed booking.",
                                  params: {
                                    date:       "string — reservation date as an ISO 8601 date (YYYY-MM-DD)",
                                    time:       "string — reservation time as HH:MM (24-hour), e.g. \"20:00\"",
                                    party_size: "integer — number of guests",
                                  }) do |args|
  conn = ActiveRecord::Base.connection

  date       = (args[:date] || args["date"]).to_s
  time       = (args[:time] || args["time"]).to_s
  party_size = (args[:party_size] || args["party_size"]).to_i
  raise Kiosk::Server::Errors::BadRequest.new("missing param: date")       if date.empty?
  raise Kiosk::Server::Errors::BadRequest.new("missing param: time")       if time.empty?
  raise Kiosk::Server::Errors::BadRequest.new("party_size must be >= 1")    if party_size < 1

  # Identity is set via Kiosk::Server::SessionContext SET LOCAL —
  # current_user_id() returns the principal. ActiveRecord doesn't have direct
  # access; pull from PG.
  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]

  conn.transaction do
    # Claim an open slot atomically (FOR UPDATE SKIP LOCKED so concurrent
    # bookers never claim the same table). Match date + time + capacity.
    slot = conn.execute(
      "SELECT ts.id, ts.restaurant_id FROM table_slots ts " \
      "WHERE ts.status = 'open' " \
      "AND ts.slot_date = #{conn.quote(date)}::date " \
      "AND to_char(ts.slot_time, 'HH24:MI') = #{conn.quote(time)} " \
      "AND ts.capacity >= #{party_size} " \
      "ORDER BY ts.capacity " \
      "FOR UPDATE SKIP LOCKED " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Conflict.new("no open table for #{date} #{time} seating #{party_size}") if slot.nil?

    slot_id       = slot["id"]
    restaurant_id = slot["restaurant_id"]

    conn.execute("UPDATE table_slots SET status = 'booked', updated_at = now() WHERE id = #{slot_id}")

    booking = conn.execute(
      "INSERT INTO bookings " \
      "(id, user_id, restaurant_id, table_slot_id, party_size, status, created_at, updated_at) " \
      "VALUES (gen_random_uuid(), #{conn.quote(uid.to_s)}::uuid, #{restaurant_id}, #{slot_id}, " \
      "#{party_size}, 'confirmed', now(), now()) " \
      "RETURNING id, party_size, status"
    ).first

    {
      booking_id:    booking["id"],
      restaurant_id: restaurant_id,
      table_slot_id: slot_id,
      party_size:    booking["party_size"].to_i,
      date:          date,
      time:          time,
      status:        booking["status"],
    }
  end
end

# cancel_booking — cancel one of the authenticated principal's own bookings and
# free the table-slot. Owner-scoped: the WHERE gates on user_id =
# kiosk.current_user_id(), so a cross-principal cancel on another's booking is a
# clean 403 (the booking is not found under the caller's identity).
Kiosk::Server::Actions.register("cancel_booking",
  description: "Cancel one of the authenticated principal's own table bookings " \
               "(requires the booking to belong to the principal). Frees the table-slot.",
  params: {
    booking_id: "uuid — the booking to cancel (from book_table / my_bookings; must belong to the principal)",
  }) do |args|
  conn = ActiveRecord::Base.connection

  booking_id = args[:booking_id] || args["booking_id"]
  raise Kiosk::Server::Errors::BadRequest.new("missing field: booking_id") if booking_id.nil? || booking_id.to_s.empty?

  conn.transaction do
    # Owner-scoped: the booking must belong to the caller and not be cancelled.
    booking = conn.execute(
      "SELECT id, table_slot_id FROM bookings " \
      "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id() " \
      "AND status <> 'cancelled' " \
      "LIMIT 1"
    ).first
    raise Kiosk::Server::Errors::Forbidden.new("booking not found, not yours, or already cancelled") if booking.nil?

    slot_id = booking["table_slot_id"]

    conn.execute(
      "UPDATE bookings SET status = 'cancelled', updated_at = now() " \
      "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
      "AND user_id = kiosk.current_user_id()"
    )
    # Free the slot so it can be booked again.
    conn.execute("UPDATE table_slots SET status = 'open', updated_at = now() WHERE id = #{slot_id}")

    { booking_id: booking_id, status: "cancelled" }
  end
end
