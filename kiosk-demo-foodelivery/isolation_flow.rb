# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver (R1 Phase 1 Task 1).
#
# Proves app-layer predicates enforce cross-tenant denial, including the
# order-ownership mutation gate that binds pay to a placed order (K-185):
#
#   HEADLINE (pay/order binding) — B cannot confirm_order on A's order:
#     Principal A places order oA and pays for it (the cart mandate binds the
#     settlement to oA via line_items[{order_id}]). Principal B calls
#     run confirm_order with order_id = oA → MUST be 403. confirm_order gates
#     on both order-ownership (oA.user_id == current_user) AND an existing
#     settlement referencing oA, so a cross-principal confirm is rejected.
#
#   Assertion 1 — exclusion:
#     Principal A places order oA. Principal B calls query my_orders
#     → B's rows must NOT contain oA.
#
#   Assertion 2 — forged user_id ignored:
#     Principal B calls run place_order with a forged user_id arg (A's user_id).
#     → The created order belongs to B (kiosk.current_user_id()), not A.
#       B's my_orders contains oB; A's my_orders does NOT contain oB.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3002 \
#   KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby isolation_flow.rb
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

# Sign the AP2 mandate chain for `order_id` and POST /kiosk/pay. The cart
# mandate carries the order_id in line_items so the settlement is bound to a
# specific placed order (K-185) — this is what confirm_order's Gate 2 checks.
def pay_for_order(server, issuer, token, key, user_id, agent_id, order_id, total_cents)
  now        = Time.now.to_i
  intent_id  = SecureRandom.uuid
  cart_id    = SecureRandom.uuid
  payment_id = SecureRandom.uuid

  intent_payload = {
    id:               intent_id,
    user_id:          user_id,
    agent_id:         agent_id,
    iss:              issuer,
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
    iss:                issuer,
    line_items:         [{ order_id: order_id, total: total_cents }],
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
    iss:             issuer,
    payment_method:  "pm_demo",
    amount_cents:    total_cents,
    currency:        "eur",
    exp:             now + 600,
    iat:             now,
  }

  intent_jws  = JWT.encode(intent_payload,  key, "RS256")
  cart_jws    = JWT.encode(cart_payload,    key, "RS256")
  payment_jws = JWT.encode(payment_payload, key, "RS256")

  post_json(
    "#{server}/kiosk/pay",
    { intent_mandate_jws: intent_jws, cart_mandate_jws: cart_jws,
      payment_mandate_jws: payment_jws },
    { "Authorization" => "Bearer #{token}" },
  )
end

# ── Step 1: Register Principal A ─────────────────────────────────────────────
key_a = OpenSSL::PKey::RSA.generate(2048)
pem_a = key_a.public_key.to_pem
rc_ch_a, ch_a = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem_a)}")
abort "challenge A failed (#{rc_ch_a}): #{JSON.generate(ch_a)}" unless rc_ch_a == 200
pop_a = JWT.encode(
  { aud: ISSUER, nonce: ch_a.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key_a, "RS256",
)
rc, reg_a = post_json(
  "#{SERVER}/kiosk/auth/register",
  { public_key: pem_a, signed: pop_a },
)
abort "register A failed (#{rc}): #{JSON.generate(reg_a)}" unless rc == 201

agent_id_a = reg_a.fetch("agent_id")
user_id_a  = reg_a.fetch("user_id")
token_a    = reg_a.fetch("access_token")

# ── Step 2: Register Principal B ─────────────────────────────────────────────
key_b = OpenSSL::PKey::RSA.generate(2048)
pem_b = key_b.public_key.to_pem
rc_ch_b, ch_b = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem_b)}")
abort "challenge B failed (#{rc_ch_b}): #{JSON.generate(ch_b)}" unless rc_ch_b == 200
pop_b = JWT.encode(
  { aud: ISSUER, nonce: ch_b.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key_b, "RS256",
)
rc, reg_b = post_json(
  "#{SERVER}/kiosk/auth/register",
  { public_key: pem_b, signed: pop_b },
)
abort "register B failed (#{rc}): #{JSON.generate(reg_b)}" unless rc == 201

agent_id_b = reg_b.fetch("agent_id")
user_id_b  = reg_b.fetch("user_id")
token_b    = reg_b.fetch("access_token")

# ── Step 3: A browses menu to find margherita ─────────────────────────────────
rc, browse = post_json(
  "#{SERVER}/kiosk/query",
  { name: "menu_by_restaurant", restaurant: "Mamma Pizza" },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "menu browse failed (#{rc}): #{JSON.generate(browse)}" unless rc == 200

rows = browse.fetch("rows", [])
margherita = rows.find { |r| r["sku"] == "margherita" }
abort "margherita not found in rows: #{JSON.generate(rows)}" unless margherita
menu_item_id = margherita.fetch("id")

# ── Step 4: A places order oA ─────────────────────────────────────────────────
rc, order_a_resp = post_json(
  "#{SERVER}/kiosk/run",
  {
    name:             "place_order",
    menu_item_id:     menu_item_id,
    quantity:         1,
    delivery_address: "1 Tenant A St, Istanbul",
  },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A place_order failed (#{rc}): #{JSON.generate(order_a_resp)}" unless rc == 200

order_id_a    = order_a_resp.dig("value", "order_id")
total_cents_a = order_a_resp.dig("value", "total_cents").to_i
abort "A's order_id missing from response: #{JSON.generate(order_a_resp)}" unless order_id_a

# ── Step 5: A pays for order oA (settlement bound to oA via the cart mandate) ─
rc, pay_a = pay_for_order(SERVER, ISSUER, token_a, key_a, user_id_a, agent_id_a, order_id_a, total_cents_a)
abort "A pay failed (#{rc}): #{JSON.generate(pay_a)}" unless rc == 200

# ── Step 6: B tries confirm_order on A's PAID order (HEADLINE — MUST be 403) ─
# B is authenticated (own token); it names A's order_id directly. The
# order-ownership gate in confirm_order must reject: the order is not B's.
b_confirm_on_a_status, _b_confirm_on_a_resp = post_json(
  "#{SERVER}/kiosk/run",
  { name: "confirm_order", order_id: order_id_a },
  { "Authorization" => "Bearer #{token_b}" },
)

# ── Step 7: A confirms own order oA (positive control — MUST succeed) ────────
rc, confirm_a = post_json(
  "#{SERVER}/kiosk/run",
  { name: "confirm_order", order_id: order_id_a },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A confirm_order (own paid order) failed (#{rc}): #{JSON.generate(confirm_a)}" unless rc == 200

# ── Step 8: B queries my_orders BEFORE placing anything (Assertion 1 data) ───
rc, b_before_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_orders" },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (before) failed (#{rc}): #{JSON.generate(b_before_resp)}" unless rc == 200
b_order_ids_before = (b_before_resp["rows"] || []).map { |r| r["id"] }

# ── Step 9: B places order with FORGED user_id arg (Assertion 2) ─────────────
rc, forged_resp = post_json(
  "#{SERVER}/kiosk/run",
  {
    name:             "place_order",
    menu_item_id:     menu_item_id,
    quantity:         1,
    delivery_address: "2 Forged St, Istanbul",
    user_id:          user_id_a,  # adversarial: B supplies A's user_id
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B forged place_order failed (#{rc}): #{JSON.generate(forged_resp)}" unless rc == 200

order_id_b = forged_resp.dig("value", "order_id")
abort "B's forged order_id missing from response: #{JSON.generate(forged_resp)}" unless order_id_b

# ── Step 10: B queries my_orders AFTER placing (must include oB, not oA) ─────
rc, b_after_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_orders" },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (after) failed (#{rc}): #{JSON.generate(b_after_resp)}" unless rc == 200
b_order_ids_after = (b_after_resp["rows"] || []).map { |r| r["id"] }

# ── Step 11: A queries my_orders AFTER B's forged order (must NOT include oB) ─
rc, a_after_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_orders" },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A my_orders (after) failed (#{rc}): #{JSON.generate(a_after_resp)}" unless rc == 200
a_order_ids_after = (a_after_resp["rows"] || []).map { |r| r["id"] }

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:               user_id_a,
  user_id_b:               user_id_b,
  agent_id_a:              agent_id_a,
  agent_id_b:              agent_id_b,
  order_id_a:              order_id_a,
  order_id_b:              order_id_b,
  b_confirm_on_a_status:   b_confirm_on_a_status,
  b_order_ids_before:      b_order_ids_before,
  b_order_ids_after:       b_order_ids_after,
  a_order_ids_after:       a_order_ids_after,
)
