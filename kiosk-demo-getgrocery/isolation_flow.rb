# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver (P6 corrected surface).
#
# Assertions:
#   Assertion 1: B's my_orders excludes A's order (cross-tenant read exclusion)
#   Assertion 2 (HEADLINE): B cannot schedule_delivery on A's order → 403
#   Assertion 3: A schedules own order (positive control for schedule gate)
#   Assertion 4: B creates own order + schedules → positive control
#   Assertion 5: B's my_orders includes own order (positive control)
#   Assertion 6: B's my_orders still excludes A's order
#   Assertion 7: A's my_orders excludes B's order
#   Assertion 8: DB — forged user_id on create_order ignored (order.user_id = B's)
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
#   bundle exec ruby isolation_flow.rb

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
    scope:            "grocery",
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
    # No payment_method: SetupIntent model — on-file card resolved by the
    # Stripe adapter; the server persists "on_file" as an audit sentinel.
    amount_cents:    total_cents,
    currency:        "eur",
    exp:             now + 600,
    iat:             now,
  }

  intent_jws  = JWT.encode(intent_payload,  key, "RS256")
  cart_jws    = JWT.encode(cart_payload,    key, "RS256")
  payment_jws = JWT.encode(payment_payload, key, "RS256")

  post_json(
    "#{server}/kiosk/exec",
    { command: "pay", body: { intent_mandate_jws: intent_jws, cart_mandate_jws: cart_jws,
                               payment_mandate_jws: payment_jws } },
    { "Authorization" => "Bearer #{token}" },
  )
end

# ── Step 1: Register Principal A ─────────────────────────────────────────────
key_a = OpenSSL::PKey::RSA.generate(2048)
rc, reg_a = post_json(
  "#{SERVER}/kiosk/agents/register",
  { name: "alice-agent", public_key: key_a.public_key.to_pem, role: "customer" },
)
abort "register A failed (#{rc}): #{JSON.generate(reg_a)}" unless rc == 201
agent_id_a = reg_a.fetch("agent_id")
user_id_a  = reg_a.fetch("user_id")
token_a    = reg_a.fetch("access_token")

# No card-setup step: this suite runs with KIOSK_TEST_AUTOCARD=1, so the adapter
# auto-provisions a test card at capture (off_session pay settles).

# ── Step 2: Register Principal B ─────────────────────────────────────────────
key_b = OpenSSL::PKey::RSA.generate(2048)
rc, reg_b = post_json(
  "#{SERVER}/kiosk/agents/register",
  { name: "bob-agent", public_key: key_b.public_key.to_pem, role: "customer" },
)
abort "register B failed (#{rc}): #{JSON.generate(reg_b)}" unless rc == 201
agent_id_b = reg_b.fetch("agent_id")
user_id_b  = reg_b.fetch("user_id")
token_b    = reg_b.fetch("access_token")

# ── Step 3: Query catalog (shared) ───────────────────────────────────────────
rc, catalog_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "catalog" } },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "catalog failed (#{rc}): #{JSON.generate(catalog_resp)}" unless rc == 200
catalog = catalog_resp.fetch("rows", [])
abort "catalog empty" if catalog.empty?
product = catalog.first
product_sku = product.fetch("sku")

# ── Step 4: A creates order_a ─────────────────────────────────────────────────
rc, order_a_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "create_order", items: [{ sku: product_sku, qty: 1 }] } },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A create_order failed (#{rc}): #{JSON.generate(order_a_resp)}" unless rc == 200
order_id_a    = order_a_resp.dig("value", "order_id")
total_cents_a = order_a_resp.dig("value", "total_cents").to_i
abort "order_id_a missing" unless order_id_a

# ── Step 5: A pays for order_a ────────────────────────────────────────────────
rc, _pay_a = pay_for_order(SERVER, ISSUER, token_a, key_a, user_id_a, agent_id_a, order_id_a, total_cents_a)
abort "A pay failed (#{rc})" unless rc == 200

# ── Step 6: B queries my_orders (before having any orders) ───────────────────
rc, b_before_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (before) failed (#{rc})" unless rc == 200
b_my_orders_before = (b_before_resp["rows"] || []).map { |r| r["id"] }

# ── Step 7: B tries schedule_delivery on A's order (MUST be 403) ─────────────
b_schedule_on_a_status, _b_schedule_on_a_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:             "schedule_delivery",
      order_id:         order_id_a,
      delivery_slot_id: 1,
      delivery_address: "2 Evil St, Neo-Tokyo",
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)

# ── Step 8: A schedules own order (MUST succeed) ──────────────────────────────
rc, sched_a = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:             "schedule_delivery",
      order_id:         order_id_a,
      delivery_slot_id: 2,
      delivery_address: "1 Good St, Neo-Tokyo",
    },
  },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A schedule_delivery failed (#{rc}): #{JSON.generate(sched_a)}" unless rc == 200

# ── Step 9: B calls create_order with forged user_id ─────────────────────────
rc, forged_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:       "create_order",
      items:      [{ sku: product_sku, qty: 1 }],
      user_id:    user_id_a,  # adversarial: B supplies A's user_id
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B forged create_order failed (#{rc}): #{JSON.generate(forged_resp)}" unless rc == 200
order_id_b_forged = forged_resp.dig("value", "order_id")
abort "order_id_b_forged missing" unless order_id_b_forged

# ── Step 10: B creates genuine order, pays, schedules ────────────────────────
rc, order_b_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "create_order", items: [{ sku: product_sku, qty: 1 }] } },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B create_order (genuine) failed (#{rc}): #{JSON.generate(order_b_resp)}" unless rc == 200
order_id_b    = order_b_resp.dig("value", "order_id")
total_cents_b = order_b_resp.dig("value", "total_cents").to_i
abort "order_id_b missing" unless order_id_b

rc, _pay_b = pay_for_order(SERVER, ISSUER, token_b, key_b, user_id_b, agent_id_b, order_id_b, total_cents_b)
abort "B pay failed (#{rc})" unless rc == 200

rc, sched_b = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:             "schedule_delivery",
      order_id:         order_id_b,
      delivery_slot_id: 1,
      delivery_address: "3 Bob St, Neo-Tokyo",
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B schedule_delivery failed (#{rc}): #{JSON.generate(sched_b)}" unless rc == 200

# ── Step 11: B queries my_orders after creating own order ─────────────────────
rc, b_after_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (after) failed (#{rc})" unless rc == 200
b_my_orders_after = (b_after_resp["rows"] || []).map { |r| r["id"] }

# ── Step 12: A queries my_orders after B's positive control ───────────────────
rc, a_after_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A my_orders (after) failed (#{rc})" unless rc == 200
a_my_orders_after = (a_after_resp["rows"] || []).map { |r| r["id"] }

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:               user_id_a,
  user_id_b:               user_id_b,
  agent_id_a:              agent_id_a,
  agent_id_b:              agent_id_b,
  order_id_a:              order_id_a,
  order_id_b:              order_id_b,
  order_id_b_forged:       order_id_b_forged,
  b_schedule_on_a_status:  b_schedule_on_a_status,
  b_my_orders_before:      b_my_orders_before,
  b_my_orders_after:       b_my_orders_after,
  a_my_orders_after:       a_my_orders_after,
)
