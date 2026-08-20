# frozen_string_literal: true

# Agent-side driver: KYC-gated motorcycle rental + scooter positive control.
#
# Proves the named-anonymized-attribute KYC gate end-to-end AND that an
# EXTERNAL agent — holding ONLY its own keypair, with NO pre-shared issuer key
# — can COMPLETE motorcycle KYC by relaying a human-approve link (K-440/K-443):
#
#   MOTORCYCLE (KYC-gated on age_over_18 AND licence_a):
#     register (PoW) → reserve(MC-001) → pay → rent_motorcycle WITHOUT KYC → 403
#     kyc_required (the problem document's `hint` points to `request_kyc`) →
#     POST /kiosk/request_kyc (skooti
#     calls the KYC broker; get a broker verification_url) → SIMULATE the
#     human approving on the BROKER page (POST <broker>/verify with the request
#     token) → the broker POSTs its signed claim to skooti's /kyc/callback → poll
#     query kyc_status until approved → submit the broker kyc_jws to POST
#     /kiosk/agents/kyc → rent_motorcycle → 200 (offline rental token unlocks).
#
#   The agent NEVER holds the broker's signing key: the claim is minted by the
#   KYC broker when the human approves, delivered to skooti's callback, and
#   relayed back through kyc_status. This is what makes the flow externally
#   completable — and the issuer is now a SHARED broker, not skooti's own stub.
#
#   SCOOTER (positive control — NO KYC at all, K-442):
#     register (PoW) → reserve(SK-001) → pay → start_rental → 200, with NO KYC
#     submitted. A licence-free scooter needs no attestation whatsoever — the
#     only KYC gate in skooti lives on rent_motorcycle (age_over_18 + licence_a).
#     That is true of the VEHICLE, not of the verb: since K-687 start_rental
#     refuses a needs_licence vehicle outright and sends the caller to
#     rent_motorcycle, because otherwise reserve(MC-001) → pay → start_rental
#     minted an unlock token for the motorcycle with no attestation at all
#     (redteam MotorcycleViaStartRental covers that path; this driver only ever
#     drove start_rental with SK-001, which is why it never saw it).
#
# Prints ONE JSON line on stdout; non-zero exit on unexpected failures.

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "lock_sim"
require "dev_unlock_key"
require_relative "../lib/equihash_register"
require_relative "../lib/prove_test_issuer"

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

def get_json(url, headers = {}, params = {})
  uri = URI(url)
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# POST a form to the stub KYC-provider page (models the human clicking
# [Approve]). This is the ONLY step that stands in for a human; it carries the
# request token, NOT any signing key.
def post_form(url, form)
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/x-www-form-urlencoded")
  req.body = URI.encode_www_form(form)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, res.body.to_s]
end

# Register a fresh agent, returning [key, agent_id, user_id, token].
def register_agent
  key, reg = equihash_register(
    server: SERVER, issuer: ISSUER,
    get_json: method(:get_json), post_json: method(:post_json),
  )
  [key, reg.fetch("agent_id"), reg.fetch("user_id"), reg.fetch("access_token")]
end

# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the QUERY STRING; an action is `POST <endpoint>/<action-name>` with its
# arguments as the JSON BODY. There is no `name` field and no /query or /run
# endpoint. A success body IS the result — a bare array from a non-paginating
# query, the action's own object from an action — and an error is an RFC 9457
# problem document whose branch point is the TOP-LEVEL `code` (`message` became
# `detail`; `hint` keeps its name and its remediation contract).
#
# Reserve a vehicle by code → reservation_id.
def reserve(token, code)
  rc, rsv = post_json("#{SERVER}/kiosk/reserve", { scooter_code: code },
                      { "Authorization" => "Bearer #{token}" })
  abort "reserve #{code} failed (#{rc}): #{JSON.generate(rsv)}" unless rc == 200
  [rsv.fetch("reservation_id"), rsv.fetch("price_per_min_cents")]
end

# Sign + settle a payment for a reservation (mirrors script/rental_flow.rb's pay step).
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

# An action: its name is the PATH SEGMENT, its arguments are the whole body.
# `request_kyc` declares the closed empty object, so it is called with NO
# arguments at all — a `reservation_id: nil` it never declared is now a typed
# 400, not a field the handler ignores.
def run_action(token, name, args = {})
  post_json("#{SERVER}/kiosk/#{name}", args,
            { "Authorization" => "Bearer #{token}" })
end

# A query: name in the path, arguments in the query string, answer a bare array.
def query(token, name, params = {})
  get_json("#{SERVER}/kiosk/#{name}", { "Authorization" => "Bearer #{token}" }, params)
end

# ── PART A: motorcycle — KYC-gated on age_over_18 AND licence_a ──────────────
# Drives the EXTERNAL-completable issuer path: the agent holds ONLY its own
# keypair and obtains a signed attestation by relaying a human-approve link.

STDERR.puts "── PART A: motorcycle (KYC-gated) ──"
mc_key, mc_agent, mc_user, mc_token = register_agent
STDERR.puts "  Registered motorcycle-renter agent #{mc_agent} (own keypair only — no issuer key)"

mc_resv, mc_price = reserve(mc_token, "MC-001")
pay(mc_token, mc_key, mc_user, mc_agent, "MC-001", mc_resv, mc_price)
STDERR.puts "  Reserved + paid MC-001 (reservation #{mc_resv})"

# A1: rent_motorcycle WITHOUT KYC → 403 kyc_required (Gate 0 fires first).
# The 403 hint must point the agent at request_kyc (the K-440/K-443 fix).
rc_mc_nokyc, mc_nokyc_body = run_action(mc_token, "rent_motorcycle", { reservation_id: mc_resv })
mc_nokyc_code = mc_nokyc_body["code"]
mc_nokyc_hint = mc_nokyc_body["hint"].to_s
hint_points_to_request_kyc = mc_nokyc_hint.include?("request_kyc")
STDERR.puts "  rent_motorcycle (no KYC): http=#{rc_mc_nokyc} code=#{mc_nokyc_code.inspect}"
STDERR.puts "  403 hint points to request_kyc: #{hint_points_to_request_kyc} (#{mc_nokyc_hint.inspect})"

# A2: the agent discovers request_kyc from the hint and starts verification.
# It gets back a verification_url to relay to the human — NO issuer key involved.
rc_req, req_body = run_action(mc_token, "request_kyc")
verification_url = req_body["verification_url"]
request_id       = req_body["request_id"]
STDERR.puts "  request_kyc: http=#{rc_req} status=#{req_body["status"].inspect}"
STDERR.puts "  verification_url=#{verification_url.inspect}"
abort "request_kyc did not return a verification_url (#{rc_req}): #{JSON.generate(req_body)}" \
  if verification_url.nil? || verification_url.empty?

# A3: SIMULATE the human approving on the KYC BROKER page. The
# verification_url points at the broker; we POST the approve there (the request
# token is the only credential — no signing key). The broker signs the
# anonymized {age_over_18, licence_a} claim and POSTs it to skooti's
# /kyc/callback, which parks it for the agent to poll. Derive the broker origin
# from the verification_url so the driver need not know the broker port itself.
approve_uri  = URI(verification_url)
approve_base = "#{approve_uri.scheme}://#{approve_uri.host}:#{approve_uri.port}"
approve_rc, _approve_html = post_form("#{approve_base}/verify", { request: request_id, decision: "approve" })
STDERR.puts "  human approved KYC broker page: http=#{approve_rc}"
abort "approve page POST failed (#{approve_rc})" unless approve_rc == 200

# A4: poll query kyc_status until approved → returns the signed kyc_jws.
kyc_jws     = nil
kyc_status  = nil
20.times do
  rc_st, st_body = query(mc_token, "kyc_status", { request_id: request_id })
  abort "kyc_status query failed (#{rc_st}): #{JSON.generate(st_body)}" unless rc_st == 200
  row        = Array(st_body).first || {}
  kyc_status = row["status"]
  if kyc_status == "approved"
    kyc_jws = row["kyc_jws"]
    break
  end
  sleep 0.2
end
STDERR.puts "  kyc_status polled: status=#{kyc_status.inspect}, jws present=#{!kyc_jws.nil? && !kyc_jws.empty?}"
abort "kyc_status never reached approved (last=#{kyc_status.inspect})" unless kyc_status == "approved"
abort "kyc_status approved but returned no kyc_jws" if kyc_jws.nil? || kyc_jws.empty?

# A5: submit the ISSUER-signed jws to the EXISTING /agents/kyc endpoint — the
# KycVerifier accepts it because it is signed by the trusted key and bound to
# THIS agent's user_id (the same submission path is still exercised).
rc_kyc, kyc_body = post_json("#{SERVER}/kiosk/agents/kyc", { kyc_jws: kyc_jws },
                             { "Authorization" => "Bearer #{mc_token}" })
abort "kyc submit failed (#{rc_kyc}): #{JSON.generate(kyc_body)}" unless rc_kyc == 200
STDERR.puts "  KYC accepted: attributes=#{kyc_body["attributes"].inspect}"

# A6: retry rent_motorcycle WITH the granted KYC attributes → 200.
rc_mc_kyc, mc_kyc_body = run_action(mc_token, "rent_motorcycle", { reservation_id: mc_resv })
STDERR.puts "  rent_motorcycle (with KYC): http=#{rc_mc_kyc}"

mc_unlocked = false
if rc_mc_kyc == 200
  skooti_pub = OpenSSL::PKey.read(DevUnlockKey.public_key_pem)
  lock = LockSim.new(scooter_code: mc_kyc_body["scooter_code"], skooti_public_key: skooti_pub)
  mc_unlocked = lock.unlock(token: mc_kyc_body["rental_token"], now: Time.now.to_i)
  STDERR.puts "  motorcycle unlocked=#{mc_unlocked}"
end

# ── PART B: scooter positive control — NO KYC at all (K-442) ─────────────────

STDERR.puts "── PART B: scooter (positive control — NO KYC) ──"
sc_key, sc_agent, sc_user, sc_token = register_agent
sc_resv, sc_price = reserve(sc_token, "SK-001")
pay(sc_token, sc_key, sc_user, sc_agent, "SK-001", sc_resv, sc_price)
# NO KYC submitted at all — a fresh agent that has never attested rents a
# licence-free scooter. Proves start_rental carries NO KYC gate (K-442).
rc_sc, _sc_body = run_action(sc_token, "start_rental", { reservation_id: sc_resv })
STDERR.puts "  start_rental SK-001 (NO KYC submitted at all): http=#{rc_sc}"

# ── PART C: a NON-CANONICAL BOOLEAN SPELLING (K-656) ─────────────────────────
#
# The forged-attestation beat (redteam MotorcycleForgedKyc) proves a BAD
# SIGNATURE grants nothing. This proves the other half: a GENUINELY
# broker-signed attestation whose booleans are spelled `"true"` (a JSON string)
# and `1` grants nothing either. It runs against the agent PART A just cleared,
# so it also proves the write REPLACES the grant set — the motorcycle it
# unlocked at A6 is refused again, with `kyc_required`.
#
# This is the property the grants moved out of a jsonb column for: presence of
# a row IS the grant, only the JSON boolean `true` writes one, and the gate is
# an EXISTS with no stored value it could misread.

STDERR.puts "── PART C: non-canonical boolean spelling ──"
spelling_jws = ProveTestIssuer.attest(
  user_id: mc_user, attributes: { age_over_18: "true", licence_a: 1 },
)
rc_spelling, spelling_body = post_json("#{SERVER}/kiosk/agents/kyc", { kyc_jws: spelling_jws },
                                       { "Authorization" => "Bearer #{mc_token}" })
spelling_attrs = spelling_body.is_a?(Hash) ? spelling_body["attributes"] : nil
STDERR.puts "  \"true\"/1-spelled attestation submit: http=#{rc_spelling} attributes=#{spelling_attrs.inspect} (expect 200 and {})"
rc_mc_after_spelling, mc_after_spelling_body = run_action(mc_token, "rent_motorcycle",
                                                          { reservation_id: mc_resv })
mc_after_spelling_code = mc_after_spelling_body.is_a?(Hash) ? mc_after_spelling_body["code"] : nil
STDERR.puts "  rent_motorcycle after the string spelling: http=#{rc_mc_after_spelling} code=#{mc_after_spelling_code.inspect} (expect 403 kyc_required)"

# ── print ONE JSON line ──────────────────────────────────────────────────────

puts JSON.generate(
  http_mc_reserve_paid:        200,
  http_mc_rent_no_kyc:         rc_mc_nokyc,
  mc_rent_no_kyc_code:         mc_nokyc_code,
  mc_rent_no_kyc_hint_to_req:  hint_points_to_request_kyc,
  http_request_kyc:            rc_req,
  request_kyc_verification_url: verification_url,
  http_approve_page:           approve_rc,
  kyc_status:                  kyc_status,
  kyc_jws_relayed:             (!kyc_jws.nil? && !kyc_jws.empty?),
  http_kyc_submit:             rc_kyc,
  kyc_attributes:              kyc_body["attributes"],
  http_mc_rent_with_kyc:       rc_mc_kyc,
  mc_unlocked:                 mc_unlocked,
  http_scooter_rent_no_kyc:    rc_sc,
  scooter_rented_no_kyc:       (rc_sc == 200),
  http_spelling_kyc_submit:    rc_spelling,
  spelling_attributes:         spelling_attrs,
  http_mc_rent_after_spelling: rc_mc_after_spelling,
  mc_rent_after_spelling_code: mc_after_spelling_code,
)
