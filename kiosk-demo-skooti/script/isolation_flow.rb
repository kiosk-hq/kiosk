# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver.
#
# Proves skooti app-layer predicates enforce cross-tenant denial:
#
#   Assertion 1 — start_rental ownership denial (Gate 1 isolated):
#     Principal A reserves scooter → reservation_id rA.
#     Principal B satisfies Gate 1b (licence-free vehicle) and Gate 2 (settles
#     a payment mandate whose cart references rA) then calls run start_rental
#     {reservation_id: rA}. start_rental has no KYC gate (K-442 abolished the
#     scooter KYC gate; see register_principal below) — the only gates are
#     ownership, vehicle kind and payment.
#     → Must be denied (HTTP 403). Gate 1 WHERE user_id = kiosk.current_user_id()
#       AND status='reserved' finds nothing because rA.user_id = A ≠ B.
#     The 403 now genuinely isolates Gate 1 ownership: Gate 1b and Gate 2 are
#     both satisfied by B before the attempt, so neither could be the real blocker.
#
#   Assertion 2 — my_reservations: exclusion + positive control:
#     2a: B's query my_reservations must NOT contain rA.
#     2b (positive control): B's query must contain rB (B's own reservation),
#         proving the exclusion is not vacuous (the query returns rows for B).
#
#   Assertion 3 — the principal is not an input to reserve:
#     3a: B calls reserve with a forged user_id arg (A's UUID).
#         → 400 bad_request naming user_id. `reserve` publishes
#           `additionalProperties: false` and does not declare user_id — the
#           principal is not one of its inputs — so the declared input contract
#           refuses the forgery before the handler runs. (Through 0.3 the wire
#           ACCEPTED the argument and the handler ignored it; refusing it is the
#           stricter answer and the one the published contract requires.)
#     3b: B then reserves LEGITIMATELY. → That reservation's DB user_id is B
#         (the server writes kiosk.current_user_id()), which is the property the
#         beat is really about and which the refusal alone does not prove.
#         Verified by DB SELECT.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3004 \
#   KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby script/isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
# Valid attestations are now minted with the SHARED KYC broker key
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

def get_json(url, headers = {}, params = {})
  uri = URI(url)
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

require_relative "../lib/equihash_register"

# Register a fresh principal through the Equihash-gated /auth/register, then KYC.
# Returns [user_id, agent_id, token, key].
#
# NOT A GATE: start_rental (the licence-free scooter verb this driver
# exercises) has no KYC gate — K-442 dropped it for scooters, and start_rental's
# actual gates are 1 (ownership), 1b (vehicle kind, K-687) and 2 (payment). The
# KYC submission below is kept only so both principals carry a real attestation,
# matching a normally-onboarded agent; abort-on-failure here proves attestation
# issuance itself works, not that it is consulted by anything below. B also
# settles a payment mandate referencing rA in Step 3b, so Gate 2 does not block
# B either. After that, the ONLY gate that can deny B is Gate 1 (ownership
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

# THE 0.4 WIRE. An action is `POST <endpoint>/<action-name>` with its arguments
# as the JSON body; a query is `GET <endpoint>/<query-name>` with its arguments
# in the query string. There is no `name` field and no /query or /run endpoint.
# A success body IS the result — a bare array from a non-paginating query, the
# action's own object from an action — and an error is an RFC 9457 problem
# document whose branch point is the TOP-LEVEL `code`.

# ── Step 1: Register Principal A ─────────────────────────────────────────────
user_id_a, agent_id_a, token_a, _key_a = register_principal(name: "alice-agent")

# ── Step 2: Register Principal B ─────────────────────────────────────────────
user_id_b, agent_id_b, token_b, key_b = register_principal(name: "bob-agent")

# ── Step 3: A reserves SK-001 → reservation_id rA ───────────────────────────
rc, reserve_a_resp = post_json(
  "#{SERVER}/kiosk/reserve",
  { scooter_code: "SK-001" },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A reserve failed (#{rc}): #{JSON.generate(reserve_a_resp)}" unless rc == 200

reservation_id_a = reserve_a_resp["reservation_id"]
scooter_code_a   = reserve_a_resp["scooter_code"]
price_per_min_a  = reserve_a_resp["price_per_min_cents"].to_i
abort "A's reservation_id missing from response: #{JSON.generate(reserve_a_resp)}" unless reservation_id_a
STDERR.puts "  A reserved #{scooter_code_a}: reservation_id=#{reservation_id_a}"

# ── Step 3b: B settles a payment mandate referencing rA (satisfies Gate 2) ──
# B signs intent + cart + payment mandates with B's registered RSA key (key_b).
# The cart's line_items contain {reservation_id: rA} so that Gate 2's jsonb-
# containment check (cm.line_items @> [{reservation_id: rA}]::jsonb) passes for B.
# settlements.user_id is written from the GUC (kiosk.current_user_id() = B),
# so Gate 2's s.user_id = kiosk.current_user_id() also passes.
# After this step, only Gate 1 can deny B's start_rental(rA).
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
STDERR.puts "  B paid for rA: settlement_id=#{pay_b_resp["settlement_id"]} — Gate 2 now passes for B"

# ── Step 4a: B calls reserve with a forged user_id arg (Assertion 3a) ───────
# B supplies user_id: user_id_a adversarially. On the 0.4 wire this is REFUSED
# before the handler runs: `reserve` publishes `additionalProperties: false` and
# declares only `scooter_code` — the principal is not one of its inputs — so the
# declared input contract answers a typed 400 naming the offending parameter.
# The rake task asserts the status, the top-level `code` and that `detail` names
# `user_id`; nothing here is loosened to let the forgery through.
forged_rc, forged_resp = post_json(
  "#{SERVER}/kiosk/reserve",
  {
    scooter_code: "SK-001",
    user_id:      user_id_a,  # adversarial: B supplies A's user_id
  },
  { "Authorization" => "Bearer #{token_b}" },
)
STDERR.puts "  B reserve with a forged user_id → #{forged_rc} #{forged_resp["code"].inspect}"

# ── Step 4b: B reserves LEGITIMATELY (Assertions 2b + 3b) ───────────────────
# The half the refusal does not prove: ownership is taken from the
# AUTHENTICATED identity, not from anything the caller sent. B's own row is also
# the positive control for Assertion 2b, so it is created before the
# my_reservations query below.
rc, legit_resp = post_json(
  "#{SERVER}/kiosk/reserve",
  { scooter_code: "SK-001" },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B reserve failed (#{rc}): #{JSON.generate(legit_resp)}" unless rc == 200

reservation_id_b = legit_resp["reservation_id"]
abort "B's reservation_id missing: #{JSON.generate(legit_resp)}" unless reservation_id_b
STDERR.puts "  B reserved (owner from token): reservation_id=#{reservation_id_b}"

# ── Step 5: B queries my_reservations (Assertion 2) ─────────────────────────
# B now has reservation_id_b as its own row (Step 4b). Two assertions:
#   2a exclusion:       b_reservation_ids must NOT contain rA.
#   2b positive control: b_reservation_ids MUST contain rB, proving the
#     exclusion is non-vacuous (the query actually returns B's own rows).
rc, b_rsv_resp = get_json(
  "#{SERVER}/kiosk/my_reservations",
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_reservations failed (#{rc}): #{JSON.generate(b_rsv_resp)}" unless rc == 200

b_reservation_ids = Array(b_rsv_resp).map { |r| r["reservation_id"] }
STDERR.puts "  B my_reservations: #{b_reservation_ids.inspect}"

# ── Step 6: B calls start_rental on A's reservation_id (Assertion 1) ────────
# B rides a licence-free scooter (Gate 1b ✓, no KYC gate applies) and has a
# settled payment for rA (Gate 2 ✓).
# Gate 1 WHERE user_id = kiosk.current_user_id() AND status='reserved' finds
# nothing because rA.user_id = A ≠ B → 403.
# The 403 now genuinely isolates Gate 1 ownership, not a Gate 2 payment gap.
rc_start_b, _start_b_resp = post_json(
  "#{SERVER}/kiosk/start_rental",
  { reservation_id: reservation_id_a },
  { "Authorization" => "Bearer #{token_b}" },
)
STDERR.puts "  B start_rental on A's rA: HTTP #{rc_start_b} (expected 403)"

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:         user_id_a,
  user_id_b:         user_id_b,
  agent_id_a:        agent_id_a,
  agent_id_b:        agent_id_b,
  reservation_id_a:  reservation_id_a,
  reservation_id_b:  reservation_id_b,
  forged_refusal:    [forged_rc, forged_resp["code"], forged_resp["detail"]],
  b_start_rental_rc: rc_start_b,
  b_reservation_ids: b_reservation_ids,
)
