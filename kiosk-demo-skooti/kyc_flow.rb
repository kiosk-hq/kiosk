# frozen_string_literal: true

# Agent-side driver: KYC-gated motorcycle rental + scooter positive control.
#
# Proves the named-anonymized-attribute KYC gate end-to-end:
#
#   MOTORCYCLE (KYC-gated on age_over_18 AND licence_a):
#     register (PoW) → reserve(MC-001) → pay → rent_motorcycle WITHOUT KYC → 403
#     → submit KYC attestation {age_over_18:true, licence_a:true} → 200
#     → rent_motorcycle → 200 (offline rental token, lock-sim unlocks)
#
#   SCOOTER (positive control — the attribute gate is action-specific):
#     register (PoW) → reserve(SK-001) → pay → submit a BARE binary KYC
#     attestation (NO attributes) → start_rental → 200. Proves start_rental
#     does NOT require the motorcycle attributes (age_over_18 / licence_a) — the
#     new attribute gate lives only on rent_motorcycle, it did not leak here.
#     (start_rental's own long-standing gate is binary KYC, hence the bare
#     attestation; a fresh agent with no attributes rents the scooter fine.)
#
# Prints ONE JSON line on stdout; non-zero exit on unexpected failures.
#
# Optional env:
#   MC_KYC_ATTRS=age_over_18   — submit a PARTIAL attestation (age only, no
#                                licence_a) so rent_motorcycle stays 403 — used
#                                by the redteam beat to prove BOTH are required.

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "lock_sim"
require "dev_unlock_key"
require "stub_kyc"
require_relative "lib/equihash_register"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# ── helpers ─────────────────────────────────────────────────────────────────

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, headers = {})
  uri = URI(url)
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Register a fresh agent, returning [key, agent_id, user_id, token].
def register_agent
  key, reg = equihash_register(
    server: SERVER, issuer: ISSUER,
    get_json: method(:get_json), post_json: method(:post_json),
  )
  [key, reg.fetch("agent_id"), reg.fetch("user_id"), reg.fetch("access_token")]
end

# Reserve a vehicle by code → reservation_id.
def reserve(token, code)
  rc, rsv = post_json("#{SERVER}/kiosk/run", { name: "reserve", scooter_code: code },
                      { "Authorization" => "Bearer #{token}" })
  abort "reserve #{code} failed (#{rc}): #{JSON.generate(rsv)}" unless rc == 200
  v = rsv.fetch("value")
  [v.fetch("reservation_id"), v.fetch("price_per_min_cents")]
end

# Sign + settle a payment for a reservation (mirrors rental_flow.rb's pay step).
def pay(token, key, user_id, agent_id, code, reservation_id, price_per_min)
  now         = Time.now.to_i
  intent_id   = SecureRandom.uuid
  cart_id     = SecureRandom.uuid
  payment_id  = SecureRandom.uuid
  total_cents = price_per_min * 1
  cap_cents   = price_per_min * 10 + 100

  intent = { id: intent_id, user_id:, agent_id:, iss: ISSUER, scope: "mobility",
             cap_amount_cents: cap_cents, currency: "eur", exp: now + 600, iat: now }
  cart   = { id: cart_id, intent_mandate_id: intent_id, user_id:, agent_id:, iss: ISSUER,
             line_items: [{ sku: code, qty: 1, price_cents: price_per_min, reservation_id: }],
             total_amount_cents: total_cents, currency: "eur", exp: now + 600, iat: now }
  payment = { id: payment_id, cart_mandate_id: cart_id, user_id:, agent_id:, iss: ISSUER,
              payment_method: "pm_demo", amount_cents: total_cents, currency: "eur",
              exp: now + 600, iat: now }

  rc, resp = post_json("#{SERVER}/kiosk/pay",
                       { intent_mandate_jws:  JWT.encode(intent,  key, "RS256"),
                         cart_mandate_jws:    JWT.encode(cart,    key, "RS256"),
                         payment_mandate_jws: JWT.encode(payment, key, "RS256") },
                       { "Authorization" => "Bearer #{token}" })
  abort "pay for #{code} failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200
end

def run_action(token, name, reservation_id)
  post_json("#{SERVER}/kiosk/run", { name:, reservation_id: },
            { "Authorization" => "Bearer #{token}" })
end

# ── PART A: motorcycle — KYC-gated on age_over_18 AND licence_a ──────────────

STDERR.puts "── PART A: motorcycle (KYC-gated) ──"
mc_key, mc_agent, mc_user, mc_token = register_agent
STDERR.puts "  Registered motorcycle-renter agent #{mc_agent}"

mc_resv, mc_price = reserve(mc_token, "MC-001")
pay(mc_token, mc_key, mc_user, mc_agent, "MC-001", mc_resv, mc_price)
STDERR.puts "  Reserved + paid MC-001 (reservation #{mc_resv})"

# A1: rent_motorcycle WITHOUT KYC → 403 kyc_required (Gate 0 fires first).
rc_mc_nokyc, mc_nokyc_body = run_action(mc_token, "rent_motorcycle", mc_resv)
mc_nokyc_code = mc_nokyc_body.dig("error", "code")
STDERR.puts "  rent_motorcycle (no KYC): http=#{rc_mc_nokyc} code=#{mc_nokyc_code.inspect}"

# A2: submit the KYC attestation carrying the two anonymized boolean attributes.
# MC_KYC_ATTRS lets the redteam beat submit only a partial set to keep the 403.
attrs =
  case ENV["MC_KYC_ATTRS"]
  when "age_over_18" then { age_over_18: true }                    # partial — licence_a missing
  when nil, ""       then { age_over_18: true, licence_a: true }   # both — the happy path
  else ENV["MC_KYC_ATTRS"].split(",").to_h { |a| [a.to_sym, true] }
  end
att = StubKyc.attest(user_id: mc_user, attributes: attrs)
rc_kyc, kyc_body = post_json("#{SERVER}/kiosk/agents/kyc", { kyc_jws: att },
                             { "Authorization" => "Bearer #{mc_token}" })
abort "kyc submit failed (#{rc_kyc}): #{JSON.generate(kyc_body)}" unless rc_kyc == 200
STDERR.puts "  KYC accepted: attributes=#{kyc_body["attributes"].inspect}"

# A3: retry rent_motorcycle WITH KYC attributes → 200 (or still 403 if partial).
rc_mc_kyc, mc_kyc_body = run_action(mc_token, "rent_motorcycle", mc_resv)
STDERR.puts "  rent_motorcycle (with KYC): http=#{rc_mc_kyc}"

mc_unlocked = false
if rc_mc_kyc == 200
  v = mc_kyc_body.fetch("value", mc_kyc_body)
  skooti_pub = OpenSSL::PKey.read(DevUnlockKey.public_key_pem)
  lock = LockSim.new(scooter_code: v["scooter_code"], skooti_public_key: skooti_pub)
  mc_unlocked = lock.unlock(token: v["rental_token"], now: Time.now.to_i)
  STDERR.puts "  motorcycle unlocked=#{mc_unlocked}"
end

# ── PART B: scooter positive control — NO KYC required ───────────────────────

STDERR.puts "── PART B: scooter (positive control — no motorcycle attributes) ──"
sc_key, sc_agent, sc_user, sc_token = register_agent
sc_resv, sc_price = reserve(sc_token, "SK-001")
pay(sc_token, sc_key, sc_user, sc_agent, "SK-001", sc_resv, sc_price)
# Submit a BARE binary attestation — NO named attributes. This satisfies
# start_rental's own binary-KYC gate but grants ZERO attributes, so it proves
# the age_over_18/licence_a attribute gate did NOT leak onto start_rental.
sc_att = StubKyc.attest(user_id: sc_user) # no attributes:
rc_sc_kyc, sc_kyc_body = post_json("#{SERVER}/kiosk/agents/kyc", { kyc_jws: sc_att },
                                   { "Authorization" => "Bearer #{sc_token}" })
abort "scooter bare-KYC failed (#{rc_sc_kyc}): #{JSON.generate(sc_kyc_body)}" unless rc_sc_kyc == 200
sc_attrs_empty = (sc_kyc_body["attributes"] || {}).empty?
STDERR.puts "  Scooter agent bare KYC: attributes=#{sc_kyc_body["attributes"].inspect} (empty=#{sc_attrs_empty})"
rc_sc, sc_body = run_action(sc_token, "start_rental", sc_resv)
STDERR.puts "  start_rental SK-001 (bare KYC, NO attributes): http=#{rc_sc}"

# ── print ONE JSON line ──────────────────────────────────────────────────────

puts JSON.generate(
  http_mc_reserve_paid:      200,
  http_mc_rent_no_kyc:       rc_mc_nokyc,
  mc_rent_no_kyc_code:       mc_nokyc_code,
  http_kyc_submit:           rc_kyc,
  kyc_attributes:            kyc_body["attributes"],
  http_mc_rent_with_kyc:     rc_mc_kyc,
  mc_unlocked:               mc_unlocked,
  http_scooter_rent_no_kyc:  rc_sc,
  scooter_kyc_attrs_empty:   sc_attrs_empty,
)
