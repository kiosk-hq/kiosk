# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver (P6 corrected surface).
#
# Drives two fresh principals (A and B) through the adversarial steps and
# emits ONE JSON line of observations; the demo:isolation rake task consumes
# it and asserts (same scheme as the task's desc and its run output):
#
#   HEADLINE: B cannot reschedule_delivery on A's PAID order (order-ownership gate)
#   Assertion 1: B's my_orders excludes A's order (cross-tenant read blocked)
#   Assertion 2: B's my_orders includes own order (positive control)
#   Assertion 3: B's my_orders still excludes A's order after positive control
#   Assertion 4: A's my_orders excludes B's order
#   Assertion 5: DB orders.user_id for forged order == B (forged arg ignored)
#   Assertion 6: a re-pay of an already-settled order → 403 WITH a body (K-472)
#
# Positive controls that must simply succeed (A reschedules own paid order;
# B creates, pays and reschedules own order) abort this flow directly on
# failure. Carts mirror their orders at catalog prices (EUR) — the
# ValidatingPaymentProvider cashier check runs on every capture here.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
#   bundle exec ruby script/isolation_flow.rb

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

# Pay for an order with a cart that MIRRORS it (per create_order's pay_hint):
# one {order_id} entry plus one {sku, qty, price_cents} entry per item.
def pay_for_order(server, issuer, token, key, user_id, agent_id, order_id, total_cents, items)
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
    line_items:         [{ order_id: order_id }] + items,
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
    "#{server}/kiosk/pay",
    { intent_mandate_jws: intent_jws, cart_mandate_jws: cart_jws,
      payment_mandate_jws: payment_jws },
    { "Authorization" => "Bearer #{token}" },
  )
end

# Register PoW is solved transparently by the helper; each principal's private
# key is returned so it can sign its own pay mandates.
require_relative "../lib/equihash_register"

# ── Step 1: Register Principal A ─────────────────────────────────────────────
key_a, reg_a = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
agent_id_a = reg_a.fetch("agent_id")
user_id_a  = reg_a.fetch("user_id")
token_a    = reg_a.fetch("access_token")

# No card-setup step: this suite runs with KIOSK_TEST_AUTOCARD=1, so the adapter
# auto-provisions a test card at capture (off_session pay settles).

# ── Step 2: Register Principal B ─────────────────────────────────────────────
key_b, reg_b = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
agent_id_b = reg_b.fetch("agent_id")
user_id_b  = reg_b.fetch("user_id")
token_b    = reg_b.fetch("access_token")

# ── Step 3: Query catalog (shared) ───────────────────────────────────────────
rc, catalog_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "catalog" },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "catalog failed (#{rc}): #{JSON.generate(catalog_resp)}" unless rc == 200
catalog = catalog_resp.fetch("rows", [])
abort "catalog empty" if catalog.empty?
product      = catalog.first
product_sku  = product.fetch("sku")
mirror_items = [{ sku: product_sku, qty: 1, price_cents: product.fetch("price_cents").to_i }]

# ── Step 4: A creates order_a (delivery slot + address required) ─────────────
rc, order_a_resp = post_json(
  "#{SERVER}/kiosk/run",
  { name: "create_order", items: [{ sku: product_sku, qty: 1 }],
    delivery_slot_id: 1, delivery_address: "1 Good St, Dublin 4" },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A create_order failed (#{rc}): #{JSON.generate(order_a_resp)}" unless rc == 200
order_id_a    = order_a_resp.dig("value", "order_id")
total_cents_a = order_a_resp.dig("value", "total_cents").to_i
abort "order_id_a missing" unless order_id_a

# ── Step 5: A pays for order_a ────────────────────────────────────────────────
rc, _pay_a = pay_for_order(SERVER, ISSUER, token_a, key_a, user_id_a, agent_id_a, order_id_a, total_cents_a, mirror_items)
abort "A pay failed (#{rc})" unless rc == 200

# ── Step 6: B queries my_orders (before having any orders) ───────────────────
rc, b_before_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_orders" },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (before) failed (#{rc})" unless rc == 200
b_my_orders_before = (b_before_resp["rows"] || []).map { |r| r["order_id"] }

# ── Step 7: B tries reschedule_delivery on A's paid order (MUST be 403) ──────
b_reschedule_on_a_status, _b_reschedule_on_a_resp = post_json(
  "#{SERVER}/kiosk/run",
  {
    name:             "reschedule_delivery",
    order_id:         order_id_a,
    delivery_slot_id: 1,
    delivery_address: "2 Evil St, Dublin 4",
  },
  { "Authorization" => "Bearer #{token_b}" },
)

# ── Step 8: A reschedules own paid order (MUST succeed) ──────────────────────
rc, resched_a = post_json(
  "#{SERVER}/kiosk/run",
  {
    name:             "reschedule_delivery",
    order_id:         order_id_a,
    delivery_slot_id: 2,
  },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A reschedule_delivery failed (#{rc}): #{JSON.generate(resched_a)}" unless rc == 200

# ── Step 9: B calls create_order with forged user_id ─────────────────────────
rc, forged_resp = post_json(
  "#{SERVER}/kiosk/run",
  {
    name:             "create_order",
    items:            [{ sku: product_sku, qty: 1 }],
    delivery_slot_id: 1,
    delivery_address: "3 Bob St, Dublin 6",
    user_id:          user_id_a,  # adversarial: B supplies A's user_id
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B forged create_order failed (#{rc}): #{JSON.generate(forged_resp)}" unless rc == 200
order_id_b_forged = forged_resp.dig("value", "order_id")
abort "order_id_b_forged missing" unless order_id_b_forged

# ── Step 10: B creates genuine order, pays, reschedules ──────────────────────
rc, order_b_resp = post_json(
  "#{SERVER}/kiosk/run",
  { name: "create_order", items: [{ sku: product_sku, qty: 1 }],
    delivery_slot_id: 1, delivery_address: "3 Bob St, Dublin 6" },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B create_order (genuine) failed (#{rc}): #{JSON.generate(order_b_resp)}" unless rc == 200
order_id_b    = order_b_resp.dig("value", "order_id")
total_cents_b = order_b_resp.dig("value", "total_cents").to_i
abort "order_id_b missing" unless order_id_b

rc, _pay_b = pay_for_order(SERVER, ISSUER, token_b, key_b, user_id_b, agent_id_b, order_id_b, total_cents_b, mirror_items)
abort "B pay failed (#{rc})" unless rc == 200

# ── Step 10b (K-472): a re-pay of an ALREADY-SETTLED order must return the
# error envelope with a body, never an empty/bodiless response. This is the
# exact detour from the K-471 live run: an agent mistakes reschedule for
# "pay again," posts a second /pay for a paid order, and the operator rejects
# it (403 order already settled). Assert the REJECTION CARRIES A BODY so an
# agent can branch on error.code. We inspect the raw HTTP response (not the
# helper's parsed hash) so an empty body would be caught, not swallowed.
repay_status, repay_body = begin
  now2 = Time.now.to_i
  iid = SecureRandom.uuid; cid = SecureRandom.uuid; pid = SecureRandom.uuid
  common2 = { user_id: user_id_b, agent_id: agent_id_b, iss: ISSUER, exp: now2 + 600, iat: now2 }
  intent2 = JWT.encode(common2.merge(id: iid, scope: "grocery", cap_amount_cents: total_cents_b + 100, currency: "eur"), key_b, "RS256")
  cart2   = JWT.encode(common2.merge(id: cid, intent_mandate_id: iid, line_items: [{ order_id: order_id_b }] + mirror_items, total_amount_cents: total_cents_b, currency: "eur"), key_b, "RS256")
  pay2    = JWT.encode(common2.merge(id: pid, cart_mandate_id: cid, amount_cents: total_cents_b, currency: "eur"), key_b, "RS256")
  uri = URI("#{SERVER}/kiosk/pay")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json", "Authorization" => "Bearer #{token_b}" })
  req.body = JSON.generate(intent_mandate_jws: intent2, cart_mandate_jws: cart2, payment_mandate_jws: pay2)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, res.body.to_s]
end
# error.code parsed from the raw body (empty body ⇒ nil ⇒ assertion fails).
repay_error_code = (JSON.parse(repay_body)["error"]["code"] rescue nil)

rc, resched_b = post_json(
  "#{SERVER}/kiosk/run",
  {
    name:             "reschedule_delivery",
    order_id:         order_id_b,
    delivery_slot_id: 3,
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B reschedule_delivery failed (#{rc}): #{JSON.generate(resched_b)}" unless rc == 200

# ── Step 11: B queries my_orders after creating own order ─────────────────────
rc, b_after_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_orders" },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (after) failed (#{rc})" unless rc == 200
b_my_orders_after = (b_after_resp["rows"] || []).map { |r| r["order_id"] }

# ── Step 12: A queries my_orders after B's positive control ───────────────────
rc, a_after_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_orders" },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A my_orders (after) failed (#{rc})" unless rc == 200
a_my_orders_after = (a_after_resp["rows"] || []).map { |r| r["order_id"] }

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:                user_id_a,
  user_id_b:                user_id_b,
  agent_id_a:               agent_id_a,
  agent_id_b:               agent_id_b,
  order_id_a:               order_id_a,
  order_id_b:               order_id_b,
  order_id_b_forged:        order_id_b_forged,
  b_reschedule_on_a_status: b_reschedule_on_a_status,
  b_my_orders_before:       b_my_orders_before,
  b_my_orders_after:        b_my_orders_after,
  a_my_orders_after:        a_my_orders_after,
  repay_settled_status:     repay_status,
  repay_body_len:           repay_body.bytesize,
  repay_error_code:         repay_error_code,
)
