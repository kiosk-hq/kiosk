# frozen_string_literal: true

# Agent-side driver: no-human scooter rental end-to-end (Ed25519 offline token).
#
# Flow: register (PoW) → KYC → reserve → pay → start_rental → LockSim.unlock
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3004 \
#   KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby script/rental_flow.rb
#
# Optional env:
#   SKIP_PAY=1   — skip the pay step (start_rental should return 403)
#
# Prints ONE JSON line on stdout; non-zero exit on unexpected failures.
#
# ── TWO-TOKEN MODEL ──────────────────────────────────────────────────────────
#
# Two distinct tokens are used in this flow — they serve completely different
# purposes and MUST NOT be confused:
#
#   1. Agent token  (RS256 JWT, "Authorization: Bearer <token>")
#      Authenticates the AI assistant (agent) to the Kiosk API server.
#      Used ONLY for Kiosk HTTP API calls: register / kyc / reserve / pay /
#      start_rental. It never leaves the agent↔server channel.
#
#   2. Rental token (Ed25519 capability, short-lived, scooter-bound)
#      Issued by start_rental as an offline, self-verifying unlock credential.
#      It is signed by the skooti Ed25519 private key; the scooter lock verifies
#      it using the baked-in public key — NO server round-trip at unlock time.
#      Properties: domain-separation tag (field 0 = "kiosk-rental-v1"), 15-min
#      exp, single-use jti (replay-prevented durably by the lock's jti store).
#      Passed DIRECTLY to the scooter lock (via BLE in production, via LockSim
#      here). The agent token NEVER reaches the lock.
#
# ────────────────────────────────────────────────────────────────────────────

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "lock_sim"
require "dev_unlock_key"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
SKIP_PAY = ENV.key?("SKIP_PAY")

# ── helpers ─────────────────────────────────────────────────────────────────

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, headers = {}, params = {})
  uri = URI(url)
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

require_relative "equihash_register"

# ── Step 1: register (Equihash PoW gate: 1 proof) ───────────────────────────

STDERR.puts "  Registering (solving 1 Equihash PoW)..."
key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
STDERR.puts "  Registered."

agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")

# ── Step 2: (no KYC) ─────────────────────────────────────────────────────────
# Licence-free scooters need NO KYC (K-442) — the rental proceeds on ownership +
# payment alone. KYC gates only the combustion motorcycle (see script/kyc_flow.rb).

# ── Step 3: browse fleet via sanctioned query, then reserve ─────────────────
#
# Path C: agents call named queries (never raw SQL). Browse the available
# fleet first; find SK-001's code, then reserve it.

# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the QUERY STRING; an action is `POST <endpoint>/<action-name>` with its
# arguments as the JSON BODY. There is no `name` field and no /query or /run
# endpoint. A success body IS the result — a bare array from a non-paginating
# query, the action's own object from an action — and an error is an RFC 9457
# problem document whose branch point is the TOP-LEVEL `code`.
rc_browse, browse_resp = get_json(
  "#{SERVER}/kiosk/scooters_available",
  { "Authorization" => "Bearer #{token}" },
)
abort "query scooters_available failed (#{rc_browse}): #{JSON.generate(browse_resp)}" unless rc_browse == 200

browse_rows = Array(browse_resp)
abort "query scooters_available returned empty rows" if browse_rows.empty?

# Pick the first available scooter (seeded as SK-001).
target_scooter = browse_rows.first
target_code    = target_scooter.fetch("code")
STDERR.puts "  Browsed fleet: #{browse_rows.size} scooter(s) available, picking #{target_code}"

rc_rsv, rsv = post_json(
  "#{SERVER}/kiosk/reserve",
  { scooter_code: target_code },
  { "Authorization" => "Bearer #{token}" },
)
abort "reserve failed (#{rc_rsv}): #{JSON.generate(rsv)}" unless rc_rsv == 200

reservation_id = rsv.fetch("reservation_id")
scooter_code   = rsv.fetch("scooter_code")
price_per_min  = rsv.fetch("price_per_min_cents")
# Human-facing rate in EUR (€0.15/min), never raw cents; the wire stays cents.
price_per_min_eur = format("€%.2f", price_per_min.to_i / 100.0)

STDERR.puts "  Reserved: id=#{reservation_id} scooter=#{scooter_code} price=#{price_per_min_eur}/min"

# ── Step 4: pay ──────────────────────────────────────────────────────────────

rc_pay   = nil
pay_resp = {}

unless SKIP_PAY
  now         = Time.now.to_i
  intent_id   = SecureRandom.uuid
  cart_id     = SecureRandom.uuid
  payment_id  = SecureRandom.uuid
  cap_cents   = price_per_min * 10 + 100
  total_cents = price_per_min * 1

  intent_payload = {
    id:               intent_id,
    user_id:          user_id,
    agent_id:         agent_id,
    iss:              ISSUER,
    scope:            "mobility",
    cap_amount_cents: cap_cents,
    currency:         "eur",
    exp:              now + 600,
    iat:              now,
  }

  cart_payload = {
    id:                 cart_id,
    intent_mandate_id:  intent_id,
    user_id:            user_id,
    agent_id:           agent_id,
    iss:                ISSUER,
    line_items:         [{ sku: scooter_code, qty: 1, price_cents: price_per_min, reservation_id: reservation_id }],
    total_amount_cents: total_cents,
    currency:           "eur",
    exp:                now + 600,
    iat:                now,
  }

  payment_payload = {
    id:              payment_id,
    cart_mandate_id: cart_id,
    user_id:         user_id,
    agent_id:        agent_id,
    iss:             ISSUER,
    payment_method:  "pm_demo",
    amount_cents:    total_cents,
    currency:        "eur",
    exp:             now + 600,
    iat:             now,
  }

  intent_jws  = JWT.encode(intent_payload,  key, "RS256")
  cart_jws    = JWT.encode(cart_payload,    key, "RS256")
  payment_jws = JWT.encode(payment_payload, key, "RS256")

  rc_pay, pay_resp = post_json(
    "#{SERVER}/kiosk/pay",
    {
      intent_mandate_jws:  intent_jws,
      cart_mandate_jws:    cart_jws,
      payment_mandate_jws: payment_jws,
    },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "pay failed (#{rc_pay}): #{JSON.generate(pay_resp)}" unless rc_pay == 200
  STDERR.puts "  Payment settled: settlement_id=#{pay_resp["settlement_id"]}"
end

# ── Step 5: start_rental — server verifies gates + issues Ed25519 rental token ─

rc_rental, rental_resp = post_json(
  "#{SERVER}/kiosk/start_rental",
  { reservation_id: reservation_id },
  { "Authorization" => "Bearer #{token}" },
)

# ── Step 6: LockSim offline verify ──────────────────────────────────────────
#
# The lock is provisioned with skooti's Ed25519 PUBLIC key.
# We source it from the SAME dev keypair the server signs with (DevUnlockKey),
# ensuring both sides share the same key without duplicating any bytes.

rental_token = nil
exp          = nil
unlocked     = false

if rc_rental == 200
  rental_token = rental_resp["rental_token"]
  exp          = rental_resp["exp"]
  sc           = rental_resp["scooter_code"]

  # Provision the lock sim with skooti's public key from DevUnlockKey.
  # DevUnlockKey.private_key is an OpenSSL Ed25519 private key; read its
  # public counterpart via public_to_pem → OpenSSL::PKey.read.
  pub_pem = DevUnlockKey.public_key_pem
  skooti_pub = OpenSSL::PKey.read(pub_pem)

  lock = LockSim.new(scooter_code: sc, skooti_public_key: skooti_pub)
  now  = Time.now.to_i

  unlocked = lock.unlock(token: rental_token, now: now)

  STDERR.puts "  start_rental: scooter=#{sc} exp=#{exp} unlocked=#{unlocked}"
elsif rc_rental == 403
  STDERR.puts "  start_rental returned 403 (expected for negative gate)."
else
  abort "start_rental failed unexpectedly (#{rc_rental}): #{JSON.generate(rental_resp)}"
end

# ── Step 7: print ONE JSON line ──────────────────────────────────────────────

puts JSON.generate(
  http_register:          201,
  http_browse:            rc_browse,
  http_reserve:           rc_rsv,
  http_pay:               rc_pay,
  http_start_rental:      rc_rental,
  user_id:                user_id,
  agent_id:               agent_id,
  reservation_id:         reservation_id,
  browse_rows_count:      browse_rows.size,
  rental_token:           rental_token,
  exp:                    exp,
  unlocked:               unlocked,
)
