# frozen_string_literal: true

# Agent-side driver: no-human scooter unlock end-to-end.
#
# Flow: register (PoW) → KYC → reserve → pay → LockSim nonce → unlock → verify
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3003 \
#   KIOSK_ISSUER=http://127.0.0.1:3003 \
#   bundle exec ruby unlock_flow.rb
#
# Optional env:
#   SKIP_PAY=1    — skip the pay step (unlock should return 403)
#   SKIP_KYC=1    — skip the KYC step (unlock should return 403)
#   MASTER_KEY    — HMAC master key (default: "dev-master-key-0001")
#
# Prints ONE JSON line on stdout; non-zero exit on unexpected failures.

require "digest"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "lock_sim"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")
SKIP_PAY  = ENV.key?("SKIP_PAY")
SKIP_KYC  = ENV.key?("SKIP_KYC")
MASTER_KEY = ENV.fetch("MASTER_KEY", "dev-master-key-0001")

# ── helpers ─────────────────────────────────────────────────────────────────

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Replicates Kiosk::Server::ProofOfWork.leading_zero_bits exactly.
def leading_zero_bits(bytes)
  return 0 if bytes.empty?

  count = 0
  bytes.each_byte do |b|
    if b == 0
      count += 8
    else
      bit = 7
      bit -= 1 while bit >= 0 && b[bit] == 0
      count += (7 - bit)
      break
    end
  end
  count
end

def pow_valid?(pem, pow, difficulty)
  return true if difficulty <= 0

  digest = Digest::SHA256.digest("#{pem}.#{pow}")
  leading_zero_bits(digest) >= difficulty
end

# ── Step 1: generate RSA-2048 keypair + solve PoW (difficulty=20) ───────────

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem

STDERR.puts "  Solving PoW (difficulty=20)…"
pow = 0
pow += 1 until pow_valid?(pem, pow.to_s, 20)
STDERR.puts "  PoW solved: pow=#{pow}"

rc_reg, reg = post_json(
  "#{SERVER}/kiosk/agents/register",
  { name: "hermes-scooter", public_key: pem, role: "customer", pow: pow.to_s },
)
abort "register failed (#{rc_reg}): #{JSON.generate(reg)}" unless rc_reg == 201

agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")

# ── Step 2: KYC attestation ──────────────────────────────────────────────────

rc_kyc = nil
unless SKIP_KYC
  require_relative "lib/stub_kyc"
  att = StubKyc.attest(user_id: user_id)

  rc_kyc, kyc_resp = post_json(
    "#{SERVER}/kiosk/agents/kyc",
    { kyc_jws: att },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "kyc failed (#{rc_kyc}): #{JSON.generate(kyc_resp)}" unless rc_kyc == 200
  STDERR.puts "  KYC verified"
end

# ── Step 3: reserve a scooter (seeded scooter code = "SK-001") ──────────────

rc_rsv, rsv = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "reserve", scooter_code: "SK-001" } },
  { "Authorization" => "Bearer #{token}" },
)
abort "reserve failed (#{rc_rsv}): #{JSON.generate(rsv)}" unless rc_rsv == 200

rsv_value      = rsv.fetch("value")
reservation_id = rsv_value.fetch("reservation_id")
# The action returns the server-side scooter code (e.g. "SK-001").
scooter_code   = rsv_value.fetch("scooter_code")
price_per_min  = rsv_value.fetch("price_per_min_cents")

STDERR.puts "  Reserved: id=#{reservation_id} scooter=#{scooter_code} price=#{price_per_min}¢/min"

# ── Step 4: pay ──────────────────────────────────────────────────────────────

rc_pay = nil
pay_resp = {}

unless SKIP_PAY
  now         = Time.now.to_i
  intent_id   = SecureRandom.uuid
  cart_id     = SecureRandom.uuid
  # Cap well above the per-minute price (charge 10 min up front for the demo).
  cap_cents   = price_per_min * 10 + 100
  total_cents = price_per_min * 1  # one minute's worth for the cart

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
    line_items:         [{ sku: scooter_code, qty: 1 }],
    total_amount_cents: total_cents,
    currency:           "eur",
    exp:                now + 600,
    iat:                now,
  }

  intent_jws = JWT.encode(intent_payload, key, "RS256")
  cart_jws   = JWT.encode(cart_payload,   key, "RS256")

  rc_pay, pay_resp = post_json(
    "#{SERVER}/kiosk/exec",
    {
      command: "pay",
      body: {
        intent_mandate_jws: intent_jws,
        cart_mandate_jws:   cart_jws,
      },
    },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "pay failed (#{rc_pay}): #{JSON.generate(pay_resp)}" unless rc_pay == 200
  STDERR.puts "  Payment settled: mandate_id=#{pay_resp.dig("value", "payment_mandate_id")}"
end

# ── Step 5: instantiate LockSim with the diversified K_lock ─────────────────
#
# K_lock = HMAC-SHA256(master_key, scooter_code)
# scooter_code is "SK-001" — the physical lock identifier the firmware is
# provisioned with. This MUST match the code the server derives from the
# reservation and passes to UnlockAuthority.mac.

lock_key = OpenSSL::HMAC.digest("SHA256", MASTER_KEY, "SK-001")
lock     = LockSim.new(scooter_id: "SK-001", lock_key: lock_key)
nonce    = lock.issue_nonce

# ── Step 6: unlock ───────────────────────────────────────────────────────────
# No scooter_id in the request body — the server derives it from the reservation.

rc_unlock, unlock_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:           "unlock",
      nonce:          nonce,
      reservation_id: reservation_id,
    },
  },
  { "Authorization" => "Bearer #{token}" },
)

# ── Step 7: verify with LockSim + replay + tamper ───────────────────────────

unlocked        = false
replay_rejected = false
tamper_rejected = false
mac             = nil

if rc_unlock == 200
  unlock_value = unlock_resp.fetch("value", unlock_resp)
  mac          = unlock_value["mac"]

  # Happy path — LockSim verifies the server MAC.
  unlocked = lock.unlock(nonce_hex: nonce, reservation_id: reservation_id, mac: mac)

  # Replay test — same nonce already consumed, must return false.
  replay_rejected = !lock.unlock(nonce_hex: nonce, reservation_id: reservation_id, mac: mac)

  # Tamper test — fresh nonce but garbage MAC (as if firmware rejects forged MAC).
  fresh_nonce = lock.issue_nonce
  tamper_rejected = !lock.unlock(
    nonce_hex:      fresh_nonce,
    reservation_id: reservation_id,
    mac:            "deadbeef" * 8,
  )
elsif rc_unlock == 403
  # Negative gate path (SKIP_PAY or SKIP_KYC) — expected 403, skip sim tests.
  STDERR.puts "  Unlock returned 403 (expected for negative gate)."
else
  abort "unlock failed unexpectedly (#{rc_unlock}): #{JSON.generate(unlock_resp)}"
end

# ── Step 8: print ONE JSON line ──────────────────────────────────────────────

puts JSON.generate(
  http_register:  rc_reg,
  http_kyc:       rc_kyc,
  http_reserve:   rc_rsv,
  http_pay:       rc_pay,
  http_unlock:    rc_unlock,
  user_id:        user_id,
  agent_id:       agent_id,
  reservation_id: reservation_id,
  unlock_resp:    unlock_resp,
  mac:            mac,
  unlocked:       unlocked,
  replay_rejected: replay_rejected,
  tamper_rejected: tamper_rejected,
)
