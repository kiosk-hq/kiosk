# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver.
#
# Proves skooti app-layer predicates enforce cross-tenant denial:
#
#   Assertion 1 — start_rental ownership denial (Gate-1 isolated):
#     Principal A reserves scooter → reservation_id rA.
#     Principal B satisfies Gate-2 (KYC) and Gate-3 (settles a payment mandate
#     whose cart references rA) then calls run start_rental {reservation_id: rA}.
#     → Must be denied (HTTP 403). Gate-1 WHERE user_id = kiosk.current_user_id()
#       AND status='reserved' finds nothing because rA.user_id = A ≠ B.
#     The 403 now genuinely isolates Gate-1 ownership: Gate-2 and Gate-3 are
#     both satisfied by B before the attempt, so neither could be the real blocker.
#
#   Assertion 2 — my_reservations: exclusion + positive control:
#     2a: B's query my_reservations must NOT contain rA.
#     2b (positive control): B's query must contain rB (B's own reservation),
#         proving the exclusion is not vacuous (the query returns rows for B).
#
#   Assertion 3 — forged user_id ignored on reserve:
#     B calls run reserve with a forged user_id arg (A's UUID).
#     → The created reservation's user_id is B (server uses kiosk.current_user_id(),
#       ignores agent-supplied user_id). Verified by DB SELECT.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3003 \
#   KIOSK_ISSUER=http://127.0.0.1:3003 \
#   bundle exec ruby isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
# Valid attestations are now minted with the SHARED prove.my broker key
# (ProveTestIssuer, signing with the ProveKey skooti trusts) — the self-hosted
# StubKyc retired when issuance moved to the broker.
require "prove_test_issuer"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# ── helpers ──────────────────────────────────────────────────────────────────

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

require_relative "lib/equihash_register"

# Register a fresh principal through the Equihash-gated /auth/register, then KYC.
# Returns [user_id, agent_id, token, key].
#
# KYC is done for BOTH principals so that Gate-2 does not block B when B
# later attempts start_rental on A's reservation rA. B also settles a payment
# mandate referencing rA in Step 3b, so Gate-3 does not block B either. After
# both gates are satisfied, the ONLY gate that can deny B is Gate-1 (ownership
# predicate: rA.user_id = A ≠ B). This makes Assertion 1 genuinely isolate
# the ownership predicate rather than an incidental payment gap.
def register_principal(name:)
  STDERR.puts "  Registering #{name} (solving 1 Equihash PoW)..."
  key, reg = equihash_register(
    server: SERVER, issuer: ISSUER,
    get_json: method(:get_json), post_json: method(:post_json),
  )

  user_id  = reg.fetch("user_id")
  agent_id = reg.fetch("agent_id")
  token    = reg.fetch("access_token")

  att = ProveTestIssuer.attest(user_id: user_id)
  rc_kyc, kyc_resp = post_json(
    "#{SERVER}/kiosk/agents/kyc",
    { kyc_jws: att },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "kyc #{name} failed (#{rc_kyc}): #{JSON.generate(kyc_resp)}" unless rc_kyc == 200
  STDERR.puts "  #{name}: registered user_id=#{user_id} agent_id=#{agent_id} KYC=ok"

  [user_id, agent_id, token, key]
end

# ── Step 1: Register Principal A ─────────────────────────────────────────────
user_id_a, agent_id_a, token_a, _key_a = register_principal(name: "alice-agent")

# ── Step 2: Register Principal B ─────────────────────────────────────────────
user_id_b, agent_id_b, token_b, key_b = register_principal(name: "bob-agent")

# ── Step 3: A reserves SK-001 → reservation_id rA ───────────────────────────
rc, reserve_a_resp = post_json(
  "#{SERVER}/kiosk/run",
  { name: "reserve", scooter_code: "SK-001" },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A reserve failed (#{rc}): #{JSON.generate(reserve_a_resp)}" unless rc == 200

reservation_id_a = reserve_a_resp.dig("value", "reservation_id")
scooter_code_a   = reserve_a_resp.dig("value", "scooter_code")
price_per_min_a  = reserve_a_resp.dig("value", "price_per_min_cents").to_i
abort "A's reservation_id missing from response: #{JSON.generate(reserve_a_resp)}" unless reservation_id_a
STDERR.puts "  A reserved #{scooter_code_a}: reservation_id=#{reservation_id_a}"

# ── Step 3b: B settles a payment mandate referencing rA (satisfies Gate-3) ──
# B signs intent + cart + payment mandates with B's registered RSA key (key_b).
# The cart's line_items contain {reservation_id: rA} so that Gate-3's jsonb-
# containment check (cm.line_items @> [{reservation_id: rA}]::jsonb) passes for B.
# settlements.user_id is written from the GUC (kiosk.current_user_id() = B),
# so Gate-3's s.user_id = kiosk.current_user_id() also passes.
# After this step, only Gate-1 can deny B's start_rental(rA).
now_b        = Time.now.to_i
intent_id_b  = SecureRandom.uuid
cart_id_b    = SecureRandom.uuid
payment_id_b = SecureRandom.uuid
cap_b        = price_per_min_a * 10 + 100

intent_b_payload = {
  id:               intent_id_b,
  user_id:          user_id_b,
  agent_id:         agent_id_b,
  iss:              ISSUER,
  scope:            "mobility",
  cap_amount_cents: cap_b,
  currency:         "eur",
  exp:              now_b + 600,
  iat:              now_b,
}
cart_b_payload = {
  id:                 cart_id_b,
  intent_mandate_id:  intent_id_b,
  user_id:            user_id_b,
  agent_id:           agent_id_b,
  iss:                ISSUER,
  line_items:         [{ sku: scooter_code_a, qty: 1, reservation_id: reservation_id_a }],
  total_amount_cents: price_per_min_a,
  currency:           "eur",
  exp:                now_b + 600,
  iat:                now_b,
}
payment_b_payload = {
  id:              payment_id_b,
  cart_mandate_id: cart_id_b,
  user_id:         user_id_b,
  agent_id:        agent_id_b,
  iss:             ISSUER,
  payment_method:  "pm_demo",
  amount_cents:    price_per_min_a,
  currency:        "eur",
  exp:             now_b + 600,
  iat:             now_b,
}

intent_b_jws  = JWT.encode(intent_b_payload,  key_b, "RS256")
cart_b_jws    = JWT.encode(cart_b_payload,    key_b, "RS256")
payment_b_jws = JWT.encode(payment_b_payload, key_b, "RS256")

rc_pay_b, pay_b_resp = post_json(
  "#{SERVER}/kiosk/pay",
  {
    intent_mandate_jws:  intent_b_jws,
    cart_mandate_jws:    cart_b_jws,
    payment_mandate_jws: payment_b_jws,
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B pay (for rA) failed (#{rc_pay_b}): #{JSON.generate(pay_b_resp)}" unless rc_pay_b == 200
STDERR.puts "  B paid for rA: settlement_id=#{pay_b_resp.dig("value", "settlement_id")} — Gate-3 now passes for B"

# ── Step 4: B calls reserve with forged user_id arg (Assertion 3) ───────────
# B supplies user_id: user_id_a adversarially. The server ignores it —
# the INSERT uses kiosk.current_user_id() (B's UUID). Verified via DB query.
# Done before the my_reservations query so B has its own row for the
# positive-control half of Assertion 2b.
rc, forged_resp = post_json(
  "#{SERVER}/kiosk/run",
  {
    name:         "reserve",
    scooter_code: "SK-001",
    user_id:      user_id_a,  # adversarial: B supplies A's user_id
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B forged reserve failed (#{rc}): #{JSON.generate(forged_resp)}" unless rc == 200

reservation_id_b_forged = forged_resp.dig("value", "reservation_id")
abort "B's forged reservation_id missing: #{JSON.generate(forged_resp)}" unless reservation_id_b_forged
STDERR.puts "  B forged reserve: reservation_id=#{reservation_id_b_forged}"

# ── Step 5: B queries my_reservations (Assertion 2) ─────────────────────────
# B now has reservation_id_b_forged as its own row (Step 4). Two assertions:
#   2a exclusion:       b_reservation_ids must NOT contain rA.
#   2b positive control: b_reservation_ids MUST contain rB_forged, proving
#     the exclusion is non-vacuous (the query actually returns B's own rows).
rc, b_rsv_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_reservations" },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_reservations failed (#{rc}): #{JSON.generate(b_rsv_resp)}" unless rc == 200

b_reservation_ids = (b_rsv_resp["rows"] || []).map { |r| r["reservation_id"] }
STDERR.puts "  B my_reservations: #{b_reservation_ids.inspect}"

# ── Step 6: B calls start_rental on A's reservation_id (Assertion 1) ────────
# B is KYC-verified (Gate-2 ✓) and has a settled payment for rA (Gate-3 ✓).
# Gate-1 WHERE user_id = kiosk.current_user_id() AND status='reserved' finds
# nothing because rA.user_id = A ≠ B → 403.
# The 403 now genuinely isolates Gate-1 ownership, not a Gate-3 payment gap.
rc_start_b, start_b_resp = post_json(
  "#{SERVER}/kiosk/run",
  { name: "start_rental", reservation_id: reservation_id_a },
  { "Authorization" => "Bearer #{token_b}" },
)
STDERR.puts "  B start_rental on A's rA: HTTP #{rc_start_b} (expected 403)"

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:               user_id_a,
  user_id_b:               user_id_b,
  agent_id_a:              agent_id_a,
  agent_id_b:              agent_id_b,
  reservation_id_a:        reservation_id_a,
  reservation_id_b_forged: reservation_id_b_forged,
  b_start_rental_rc:       rc_start_b,
  b_reservation_ids:       b_reservation_ids,
)
