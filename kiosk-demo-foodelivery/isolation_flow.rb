# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver (R1 Phase 1 Task 1).
#
# Proves app-layer predicates enforce cross-tenant denial:
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
#   Assertion 3 (pay/order binding) — see ⚠️ in demo:isolation task:
#     foodelivery's pay path accepts a cart mandate with {line_items:[{sku,qty}]}
#     only; there is NO order_id binding in the mandate or pay args. A cross-
#     principal settle cannot be fabricated in the current mandate structure.
#     Documented as a ⚠️ concern rather than fabricated as a testable assertion.
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

# ── Step 3: A browses menu to find margherita ─────────────────────────────────
rc, browse = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "menu_by_restaurant", restaurant: "Mamma Pizza" } },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "menu browse failed (#{rc}): #{JSON.generate(browse)}" unless rc == 200

rows = browse.fetch("rows", [])
margherita = rows.find { |r| r["sku"] == "margherita" }
abort "margherita not found in rows: #{JSON.generate(rows)}" unless margherita
menu_item_id = margherita.fetch("id")

# ── Step 4: A places order oA ─────────────────────────────────────────────────
rc, order_a_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:             "place_order",
      menu_item_id:     menu_item_id,
      quantity:         1,
      delivery_address: "1 Tenant A St, Istanbul",
    },
  },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A place_order failed (#{rc}): #{JSON.generate(order_a_resp)}" unless rc == 200

order_id_a = order_a_resp.dig("value", "order_id")
abort "A's order_id missing from response: #{JSON.generate(order_a_resp)}" unless order_id_a

# ── Step 5: B queries my_orders BEFORE placing anything (Assertion 1 data) ───
rc, b_before_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (before) failed (#{rc}): #{JSON.generate(b_before_resp)}" unless rc == 200
b_order_ids_before = (b_before_resp["rows"] || []).map { |r| r["id"] }

# ── Step 6: B places order with FORGED user_id arg (Assertion 2) ─────────────
rc, forged_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:             "place_order",
      menu_item_id:     menu_item_id,
      quantity:         1,
      delivery_address: "2 Forged St, Istanbul",
      user_id:          user_id_a,  # adversarial: B supplies A's user_id
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B forged place_order failed (#{rc}): #{JSON.generate(forged_resp)}" unless rc == 200

order_id_b = forged_resp.dig("value", "order_id")
abort "B's forged order_id missing from response: #{JSON.generate(forged_resp)}" unless order_id_b

# ── Step 7: B queries my_orders AFTER placing (must include oB, not oA) ──────
rc, b_after_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (after) failed (#{rc}): #{JSON.generate(b_after_resp)}" unless rc == 200
b_order_ids_after = (b_after_resp["rows"] || []).map { |r| r["id"] }

# ── Step 8: A queries my_orders AFTER B's forged order (must NOT include oB) ─
rc, a_after_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A my_orders (after) failed (#{rc}): #{JSON.generate(a_after_resp)}" unless rc == 200
a_order_ids_after = (a_after_resp["rows"] || []).map { |r| r["id"] }

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:           user_id_a,
  user_id_b:           user_id_b,
  agent_id_a:          agent_id_a,
  agent_id_b:          agent_id_b,
  order_id_a:          order_id_a,
  order_id_b:          order_id_b,
  b_order_ids_before:  b_order_ids_before,
  b_order_ids_after:   b_order_ids_after,
  a_order_ids_after:   a_order_ids_after,
)
