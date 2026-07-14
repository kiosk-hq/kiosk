# frozen_string_literal: true

# Reference agent driver: no-human food order end-to-end.
#
# Generalises e2e/fixtures/pay_flow.rb to the full order flow:
#   register → browse menu (named query) → place_order (run) → sign AP2 mandates → pay
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3002 \
#   KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby order_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "jwt"
require "json"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

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

# ── Step 1: generate keypair + self-register (no human) ────────────────

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem

rc_ch, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode(
  { aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key, "RS256",
)
rc, reg = post_json(
  "#{SERVER}/kiosk/auth/register",
  { public_key: pem, signed: pop },
)
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201

agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")

# ── Step 2: browse — find the Margherita menu item via named query ───────

rc, browse = post_json(
  "#{SERVER}/kiosk/query",
  {
    name:       "menu_by_restaurant",
    restaurant: "Mamma Pizza",
  },
  { "Authorization" => "Bearer #{token}" },
)
abort "menu browse failed (#{rc}): #{JSON.generate(browse)}" unless rc == 200

rows = browse.fetch("rows", [])
margherita = rows.find { |r| r["sku"] == "margherita" }
abort "margherita not found in rows: #{JSON.generate(rows)}" unless margherita

menu_item_id = margherita.fetch("id")

# ── Step 3: place order ─────────────────────────────────────────────────

rc, run_resp = post_json(
  "#{SERVER}/kiosk/run",
  {
    name:             "place_order",
    menu_item_id:     menu_item_id,
    quantity:         1,
    delivery_address: "1 Test St, Istanbul",
  },
  { "Authorization" => "Bearer #{token}" },
)
abort "place_order failed (#{rc}): #{JSON.generate(run_resp)}" unless rc == 200

order_value  = run_resp.fetch("value")
order_id     = order_value.fetch("order_id")
total_cents  = order_value.fetch("total_cents")

# ── Step 4: sign AP2 intent + cart mandates with the agent's RSA key ───

now = Time.now.to_i
intent_id = SecureRandom.uuid
cap_amount_cents = total_cents + 100   # cap a bit above the order total

intent_payload = {
  id:               intent_id,
  user_id:          user_id,
  agent_id:         agent_id,
  iss:              ISSUER,
  scope:            "food",
  cap_amount_cents: cap_amount_cents,
  currency:         "eur",
  exp:              now + 600,
  iat:              now,
}

cart_id = SecureRandom.uuid
cart_payload = {
  id:                 cart_id,
  intent_mandate_id:  intent_id,
  user_id:            user_id,
  agent_id:           agent_id,
  iss:                ISSUER,
  # Bind the cart to the placed order (K-185): the cart mandate carries the
  # order_id so the settlement can be matched to a specific owned order, exactly
  # as getgrocery binds its cart to a create_order id. confirm_order gates on it.
  line_items:         [{ order_id: order_id, total: total_cents }],
  total_amount_cents: total_cents,
  currency:           "eur",
  exp:                now + 600,
  iat:                now,
}

payment_id = SecureRandom.uuid
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

# ── Step 5: pay ─────────────────────────────────────────────────────────

rc, pay = post_json(
  "#{SERVER}/kiosk/pay",
  {
    intent_mandate_jws:  intent_jws,
    cart_mandate_jws:    cart_jws,
    payment_mandate_jws: payment_jws,
  },
  { "Authorization" => "Bearer #{token}" },
)
abort "pay failed (#{rc}): #{JSON.generate(pay)}" unless rc == 200

# ── Step 6: confirm_order — post-pay, order-ownership + settlement gated ──
# Mirrors getgrocery's schedule_delivery: the legitimate owner confirms the
# paid order. The action re-checks ownership and that a settlement references
# this order (bound via the cart mandate's order_id), so this only succeeds
# for the order's owner after a real settlement.

rc, confirm = post_json(
  "#{SERVER}/kiosk/run",
  { name: "confirm_order", order_id: order_id },
  { "Authorization" => "Bearer #{token}" },
)
abort "confirm_order failed (#{rc}): #{JSON.generate(confirm)}" unless rc == 200

# ── Step 7: print ONE JSON line ─────────────────────────────────────────

puts JSON.generate(
  http_register: 201,
  user_id:       user_id,
  agent_id:      agent_id,
  order:         order_value,
  pay:           pay,
  confirm:       confirm,
)
