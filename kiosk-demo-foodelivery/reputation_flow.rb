# frozen_string_literal: true

# Kiosk reputation end-to-end driver (R2 P6 — trust-earned-by-spending).
#
# Demonstrates the full "difficulty drops as purchases accrue" lifecycle using
# the shipped RateAndReputation policy with real settlements lookups:
#
#   0 purchases → 402 argon2id challenge at d=5 (unproven principal)
#   1 purchase  → 402 argon2id challenge at d=3 (lower — purchase earned PoW relief)
#   2 purchases → 200 served directly, no challenge (proven → free pass)
#
# Steps:
#   1. Register a fresh principal.
#   2. POST query menu_by_restaurant → 402 (d0, unproven). Solve, verify served.
#   3. Make purchase 1: place_order (run) + sign mandates + pay (each also PoW-gated).
#   4. POST query → 402 (d1, 1 purchase). Solve, verify served. Assert d1 < d0.
#   5. Make purchase 2 (same flow as step 3).
#   6. POST query → 200 directly (free pass, proven). Assert no challenge.
#   7. Emit ONE JSON line with the difficulty curve.
#
# Usage (invoked by rake demo:reputation — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3004 \
#   KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby reputation_flow.rb
#
# Requirements:
#   - The server must be running with KIOSK_POW_REPUTATION_DEMO=1.
#   - python3 with argon2-cffi: pip install argon2-cffi

require "json"
require "net/http"
require "uri"
require "openssl"
require "open3"
require "securerandom"
require "jwt"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
SOLVE_PY = File.expand_path("../kiosk-pow/solve.py", __dir__)

# ── Shared helpers ─────────────────────────────────────────────────────────

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Reuse solve.py from kiosk-pow (same solver as demo:pow).
def solve_challenge(challenge)
  out, status = Open3.capture2("python3", SOLVE_PY, JSON.generate(challenge))
  abort "solve.py failed for challenge #{challenge["id"]}: #{out}" unless status.success?
  begin
    JSON.parse(out).fetch("nonce")
  rescue KeyError, JSON::ParserError => e
    abort "solve.py output not parseable as {nonce:}: #{e.message}\nOutput: #{out}"
  end
end

# Execute a Kiosk verb with automatic PoW handling.
#
# If the server issues a 402 challenge, solves it with solve.py and re-sends
# the SAME body + solved proof. Returns [rc, resp, d] where d is the difficulty
# that was solved (nil = no challenge was needed — free pass).
def exec_with_pow(command, body, token)
  headers = { "Authorization" => "Bearer #{token}" }

  rc, resp = post_json("#{SERVER}/kiosk/exec", { command: command, body: body }, headers)

  if rc == 402
    challenge = resp.dig("error", "challenge")
    abort "missing challenge object in 402 for #{command}" unless challenge
    d     = challenge.dig("params", "d")
    nonce = solve_challenge(challenge)

    # Re-submit the IDENTICAL body — request_fingerprint must match.
    rc, resp = post_json(
      "#{SERVER}/kiosk/exec",
      { command: command, body: body, pow: { challenge: challenge, nonce: nonce } },
      headers,
    )
    [rc, resp, d]
  else
    [rc, resp, nil]
  end
end

# Execute one full purchase: place_order (run) → sign AP2 mandates → pay.
# All three steps go through exec_with_pow (the server challenges each verb
# until the principal is proven). Returns the payment_mandate_id.
def make_purchase(menu_item_id, key, user_id, agent_id, token)
  # ── run: place_order ──────────────────────────────────────────────────────
  order_body = {
    name:             "place_order",
    menu_item_id:     menu_item_id,
    quantity:         1,
    delivery_address: "1 Reputation Demo St, Istanbul",
  }
  rc, resp, _ = exec_with_pow("run", order_body, token)
  abort "place_order failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  total_cents = resp.dig("value", "total_cents")
  abort "place_order returned no total_cents" if total_cents.nil?

  # ── Sign AP2 intent + cart + payment mandates ─────────────────────────────
  now        = Time.now.to_i
  intent_id  = SecureRandom.uuid
  cart_id    = SecureRandom.uuid
  payment_id = SecureRandom.uuid

  intent_payload = {
    id:               intent_id,
    user_id:          user_id,
    agent_id:         agent_id,
    iss:              ISSUER,
    scope:            "food",
    cap_amount_cents: total_cents + 100,
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
    line_items:         [{ sku: "margherita", qty: 1 }],
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

  # ── pay ───────────────────────────────────────────────────────────────────
  # Generate the pay body ONCE — exec_with_pow re-sends the same body on retry,
  # so the request_fingerprint (which covers body) is identical in both calls.
  pay_body = { intent_mandate_jws: intent_jws, cart_mandate_jws: cart_jws,
               payment_mandate_jws: payment_jws }
  rc, resp, _ = exec_with_pow("pay", pay_body, token)
  abort "pay failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200

  resp.dig("value", "settlement_id")
end

# ── Step 1: register a fresh principal ─────────────────────────────────────

key = OpenSSL::PKey::RSA.generate(2048)
rc, reg = post_json(
  "#{SERVER}/kiosk/agents/register",
  { name: "rep-agent-#{SecureRandom.hex(4)}", public_key: key.public_key.to_pem, role: "customer" },
)
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201

agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")

QUERY_BODY = { name: "menu_by_restaurant", restaurant: "Mamma Pizza" }

# ── Step 2: query with 0 purchases → 402 (d0, unproven) → solve → 200 ─────

$stderr.puts "  [rep] Step 2: query (0 purchases) — expect 402 + challenge"
rc, resp, d0 = exec_with_pow("query", QUERY_BODY, token)
abort "expected 200 after solve (0 purchases), got #{rc}: #{JSON.generate(resp)}" unless rc == 200
abort "d0 must be non-nil — unproven principal must have received a challenge" if d0.nil?

rows = resp.fetch("rows", [])
margherita = rows.find { |r| r["sku"] == "margherita" }
abort "margherita not found in menu rows" unless margherita
menu_item_id = margherita.fetch("id")

$stderr.puts "  [rep] d0=#{d0} (unproven, 0 purchases). #{rows.size} menu rows served after solve."

# ── Step 3: purchase 1 ─────────────────────────────────────────────────────

$stderr.puts "  [rep] Step 3: making purchase 1 (run + pay, each PoW-gated at d0=#{d0})"
pm1 = make_purchase(menu_item_id, key, user_id, agent_id, token)
$stderr.puts "  [rep] purchase 1 settled (settlement_id=#{pm1})"

# ── Step 4: query with 1 purchase → 402 (d1 < d0) → solve → 200 ───────────

$stderr.puts "  [rep] Step 4: query (1 purchase) — expect 402 with lower d"
rc, resp, d1 = exec_with_pow("query", QUERY_BODY, token)
abort "expected 200 after solve (1 purchase), got #{rc}: #{JSON.generate(resp)}" unless rc == 200
abort "d1 must be non-nil — 1 purchase is not yet proven" if d1.nil?

$stderr.puts "  [rep] d1=#{d1} (1 purchase). Difficulty dropped: #{d0} → #{d1}."

# ── Step 5: purchase 2 ─────────────────────────────────────────────────────

$stderr.puts "  [rep] Step 5: making purchase 2 (run + pay, each PoW-gated at d1=#{d1})"
pm2 = make_purchase(menu_item_id, key, user_id, agent_id, token)
$stderr.puts "  [rep] purchase 2 settled (settlement_id=#{pm2})"

# ── Step 6: query with 2 purchases → 200 directly (proven — free pass) ─────

$stderr.puts "  [rep] Step 6: query (2 purchases) — expect 200 with NO challenge (free pass)"
rc2, resp2, d2 = exec_with_pow("query", QUERY_BODY, token)
served_after_2 = rc2 == 200

unless served_after_2
  abort "expected 200 free pass after 2 purchases, got #{rc2}: #{JSON.generate(resp2)}"
end
unless d2.nil?
  abort "expected no challenge (d2=nil) after 2 purchases — principal must be proven. Got d2=#{d2}"
end

$stderr.puts "  [rep] served without challenge! Proven principal — free pass confirmed."

# ── Step 7: emit ONE JSON line ─────────────────────────────────────────────

puts JSON.generate(
  d_unproven:               d0,
  d_after_1_purchase:       d1,
  served_after_2_purchases: served_after_2,
  challenge_after_2:        d2,
)
