# frozen_string_literal: true

# Agent-side driver: the alcohol age-gate (18+ anonymized KYC) end-to-end, plus
# a non-alcohol positive control and two redteam beats. This is the LOW-liability
# age-gated-purchase showcase for anonymized KYC (KYC-DEMO-SCOPE (b)): the gate
# lives on the PURCHASE (create_order) where the transaction closes, not on a
# high-liability rental.
#
#   PART A — alcohol (KYC-gated on age_over_18):
#     register → catalog (find the age_restricted wine) → create_order WITH the
#     wine, NO KYC → 403 kyc_required (error.hint points to `request_kyc`) → run
#     request_kyc (getgrocery calls the KYC broker; get a broker
#     verification_url) → SIMULATE the human approving on the BROKER page → the
#     broker POSTs its signed {age_over_18} claim to getgrocery's /kyc/callback →
#     poll `query kyc_status` until approved → submit the broker kyc_jws to POST
#     /kiosk/agents/kyc → retry create_order WITH the wine → 200 → payment_setup →
#     pay (cart mirrors the order at catalog EUR prices) → settle.
#
#   The agent NEVER holds the broker's signing key: the claim is minted by the
#   KYC broker when the human approves, delivered to getgrocery's callback,
#   and relayed back through kyc_status.
#
#   PART B — non-alcohol positive control (NO KYC at all):
#     a fresh agent that never attested orders ONLY non-restricted groceries →
#     create_order → 200 directly. Proves the age-gate fires ONLY on alcohol.
#
#   REDTEAM:
#     R1  a FORGED age attestation (right issuer/aud, wrong signing key) submitted
#         to /agents/kyc → 403, so the alcohol create_order stays blocked.
#     R2  alcohol create_order without any KYC → 403 kyc_required (== A's first).
#
# Prints ONE JSON line on stdout; non-zero exit on unexpected failures.

require "date"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "prove_trust"

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

# POST a form to the broker's verify page (models the human clicking [Approve]).
# Carries the request token, NOT any signing key.
def post_form(url, form)
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/x-www-form-urlencoded")
  req.body = URI.encode_www_form(form)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, res.body.to_s]
end

require_relative "../lib/equihash_register"

# Register a fresh agent through the proof-of-possession handshake, solving the
# Equihash register PoW transparently. Returns [key, agent_id, user_id, token].
def register_agent
  key, reg = equihash_register(
    server: SERVER, issuer: ISSUER,
    get_json: method(:get_json), post_json: method(:post_json),
  )
  [key, reg.fetch("agent_id"), reg.fetch("user_id"), reg.fetch("access_token")]
end

def query(token, body)
  post_json("#{SERVER}/kiosk/query", body, { "Authorization" => "Bearer #{token}" })
end

def catalog(token)
  rc, resp = query(token, { name: "catalog" })
  abort "catalog failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  resp.fetch("rows", [])
end

# create_order with a given item set (each {sku, qty:1}). Returns [http, body].
def create_order(token, items, address: "42 Camden Street, Dublin 2", slot_id: 1)
  post_json(
    "#{SERVER}/kiosk/run",
    { name: "create_order", items: items, delivery_slot_id: slot_id, delivery_address: address },
    { "Authorization" => "Bearer #{token}" },
  )
end

# Sign + settle a payment mirroring the order (cashier check). Returns [http, body].
def pay_for_order(token, key, user_id, agent_id, order_id, total_cents, mirror_lines)
  now        = Time.now.to_i
  intent_id  = SecureRandom.uuid
  cart_id    = SecureRandom.uuid
  payment_id = SecureRandom.uuid

  intent = { id: intent_id, user_id:, agent_id:, iss: ISSUER, scope: "grocery",
             cap_amount_cents: total_cents + 200, currency: "eur", exp: now + 600, iat: now }
  cart   = { id: cart_id, intent_mandate_id: intent_id, user_id:, agent_id:, iss: ISSUER,
             line_items: [{ order_id: order_id }] + mirror_lines,
             total_amount_cents: total_cents, currency: "eur", exp: now + 600, iat: now }
  payment = { id: payment_id, cart_mandate_id: cart_id, user_id:, agent_id:, iss: ISSUER,
              amount_cents: total_cents, currency: "eur", exp: now + 600, iat: now }

  post_json(
    "#{SERVER}/kiosk/pay",
    { intent_mandate_jws:  JWT.encode(intent,  key, "RS256"),
      cart_mandate_jws:    JWT.encode(cart,    key, "RS256"),
      payment_mandate_jws: JWT.encode(payment, key, "RS256") },
    { "Authorization" => "Bearer #{token}" },
  )
end

# ── PART A: alcohol — KYC-gated on age_over_18 ────────────────────────────────

STDERR.puts "── PART A: alcohol order (age-gated on age_over_18) ──"
a_key, a_agent, a_user, a_token = register_agent
STDERR.puts "  Registered alcohol-buyer agent #{a_agent} (own keypair only — no issuer key)"

rows       = catalog(a_token)
wine       = rows.find { |r| r["age_restricted"] == true }
abort "catalog has no age_restricted item — seed the wine" if wine.nil?
non_wine   = rows.find { |r| !r["age_restricted"] } || rows.first
STDERR.puts "  Age-restricted item in catalog: sku=#{wine["sku"]} #{wine["price_eur"]}"

alcohol_items = [{ sku: wine["sku"], qty: 1 }]

# A1: create_order WITH the wine, no KYC → 403 kyc_required, hint → request_kyc.
rc_a_nokyc, a_nokyc_body = create_order(a_token, alcohol_items)
a_nokyc_code = a_nokyc_body.dig("error", "code")
a_nokyc_hint = a_nokyc_body.dig("error", "hint").to_s
hint_points_to_request_kyc = a_nokyc_hint.include?("request_kyc")
STDERR.puts "  create_order (alcohol, no KYC): http=#{rc_a_nokyc} code=#{a_nokyc_code.inspect}"
STDERR.puts "  403 hint points to request_kyc: #{hint_points_to_request_kyc}"

# A2: discover request_kyc from the hint; get a broker verification_url.
rc_req, req_body = post_json("#{SERVER}/kiosk/run", { name: "request_kyc" },
                             { "Authorization" => "Bearer #{a_token}" })
req_val          = req_body.fetch("value", {})
verification_url = req_val["verification_url"]
request_id       = req_val["request_id"]
STDERR.puts "  request_kyc: http=#{rc_req} verification_url=#{verification_url.inspect}"
abort "request_kyc did not return a verification_url (#{rc_req}): #{JSON.generate(req_body)}" \
  if verification_url.nil? || verification_url.empty?

# A3: SIMULATE the human approving on the KYC BROKER page. Derive the broker
# origin from the verification_url so the driver need not know the broker port.
approve_uri  = URI(verification_url)
approve_base = "#{approve_uri.scheme}://#{approve_uri.host}:#{approve_uri.port}"
approve_rc, _html = post_form("#{approve_base}/verify", { request: request_id, decision: "approve" })
STDERR.puts "  human approved KYC broker page: http=#{approve_rc}"
abort "approve page POST failed (#{approve_rc})" unless approve_rc == 200

# A4: poll query kyc_status until approved → returns the signed kyc_jws.
kyc_jws    = nil
kyc_status = nil
20.times do
  rc_st, st_body = query(a_token, { name: "kyc_status", request_id: request_id })
  abort "kyc_status failed (#{rc_st}): #{JSON.generate(st_body)}" unless rc_st == 200
  row = (st_body["rows"] || []).first || {}
  kyc_status = row["status"]
  if kyc_status == "approved"
    kyc_jws = row["kyc_jws"]
    break
  end
  sleep 0.2
end
STDERR.puts "  kyc_status polled: status=#{kyc_status.inspect}, jws present=#{!kyc_jws.nil? && !kyc_jws.empty?}"
abort "kyc_status never reached approved (last=#{kyc_status.inspect})" unless kyc_status == "approved"

# A5: submit the broker-signed jws to /agents/kyc → records {age_over_18}.
rc_kyc, kyc_body = post_json("#{SERVER}/kiosk/agents/kyc", { kyc_jws: kyc_jws },
                             { "Authorization" => "Bearer #{a_token}" })
STDERR.puts "  KYC submit: http=#{rc_kyc} attributes=#{kyc_body["attributes"].inspect}"

# A6: retry create_order WITH the wine → 200 now that age_over_18 is on file.
rc_a_kyc, a_kyc_body = create_order(a_token, alcohol_items)
a_order   = a_kyc_body.fetch("value", {})
a_order_id = a_order["order_id"]
a_total    = a_order["total_cents"].to_i
STDERR.puts "  create_order (alcohol, WITH KYC): http=#{rc_a_kyc} order_id=#{a_order_id.inspect}"

# A7: payment_setup + pay (cart mirrors the alcohol order at catalog prices).
rc_setup, setup_resp = post_json("#{SERVER}/kiosk/run", { name: "payment_setup" },
                                 { "Authorization" => "Bearer #{a_token}" })
STDERR.puts "  payment_setup: http=#{rc_setup} status=#{setup_resp.dig("value", "status").inspect}"

mirror = [{ sku: wine["sku"], qty: 1, price_cents: wine["price_cents"].to_i }]
rc_pay, pay_body = a_order_id ? pay_for_order(a_token, a_key, a_user, a_agent, a_order_id, a_total, mirror) : [0, {}]
psp_ref = pay_body.dig("value", "psp_reference").to_s
STDERR.puts "  pay: http=#{rc_pay} psp_reference=#{psp_ref.inspect}"

# ── PART B: non-alcohol positive control — NO KYC at all ──────────────────────

STDERR.puts "── PART B: non-alcohol order (positive control — NO KYC) ──"
b_key, b_agent, b_user, b_token = register_agent
b_rows  = catalog(b_token)
b_item  = b_rows.find { |r| !r["age_restricted"] }
rc_b, b_body = create_order(b_token, [{ sku: b_item["sku"], qty: 1 }])
b_order_id = b_body.dig("value", "order_id")
STDERR.puts "  create_order (#{b_item["sku"]}, NO KYC submitted): http=#{rc_b} order_id=#{b_order_id.inspect}"

# ── REDTEAM ───────────────────────────────────────────────────────────────────

STDERR.puts "── REDTEAM ──"
# R1: a FORGED age attestation (trusted issuer + correct aud, but signed with a
# DIFFERENT key) is rejected at /agents/kyc, so alcohol create_order stays blocked.
rt_key, rt_agent, rt_user, rt_token = register_agent
forged_signing_key = OpenSSL::PKey::RSA.generate(2048)
now = Time.now.to_i
forged_jws = JWT.encode(
  { sub: rt_user, level: "verified", iss: ProveTrust.issuer, aud: ProveTrust.operator_id,
    attributes: { age_over_18: true }, iat: now, exp: now + 3600 },
  forged_signing_key, "RS256",
)
rc_forged, forged_body = post_json("#{SERVER}/kiosk/agents/kyc", { kyc_jws: forged_jws },
                                   { "Authorization" => "Bearer #{rt_token}" })
STDERR.puts "  forged attestation submit: http=#{rc_forged} (expect 403)"
rc_rt_alcohol, _ = create_order(rt_token, alcohol_items)
STDERR.puts "  alcohol create_order after forged KYC: http=#{rc_rt_alcohol} (expect 403 kyc_required)"

# ── print ONE JSON line ────────────────────────────────────────────────────────

puts JSON.generate(
  # PART A
  http_alcohol_no_kyc:        rc_a_nokyc,
  alcohol_no_kyc_code:        a_nokyc_code,
  alcohol_no_kyc_hint_to_req: hint_points_to_request_kyc,
  http_request_kyc:           rc_req,
  request_kyc_verification_url: verification_url,
  http_approve_page:          approve_rc,
  kyc_status:                 kyc_status,
  kyc_jws_relayed:            (!kyc_jws.nil? && !kyc_jws.empty?),
  http_kyc_submit:            rc_kyc,
  kyc_attributes:             kyc_body["attributes"],
  http_alcohol_with_kyc:      rc_a_kyc,
  alcohol_order_id:           a_order_id,
  http_payment_setup:         rc_setup,
  http_pay:                   rc_pay,
  psp_reference:              psp_ref,
  # PART B
  http_nonalcohol_no_kyc:     rc_b,
  nonalcohol_order_id:        b_order_id,
  # REDTEAM
  http_forged_kyc_submit:     rc_forged,
  http_alcohol_after_forged:  rc_rt_alcohol,
)
