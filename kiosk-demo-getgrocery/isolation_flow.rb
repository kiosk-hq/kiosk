# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver (R3 Phase 2 Task 4).
#
# Proves app-layer predicates enforce cross-tenant denial — including
# getgrocery's distinctive cart-ownership mutation gates:
#
#   Assertion 1 (cart-ownership — apply_substitution):
#     Principal A adds an OOS item to cart.  Principal B calls
#     apply_substitution with cart_id_a → must be 403.
#
#   Assertion 2 (cart-ownership — confirm_delivery):
#     Principal B calls confirm_delivery with cart_id_a → must be 403.
#
#   Assertion 3 (cross-tenant read exclusion):
#     A confirms delivery → delivery_id_a.  B queries my_orders → must NOT
#     contain delivery_id_a.
#
#   Assertion 4 (forged user_id ignored):
#     B calls add_to_cart with a forged user_id arg (A's user_id).
#     The cart must belong to B (kiosk.current_user_id()), not A.
#
#   Assertion 5 (positive control + cross-tenant):
#     B creates own delivery (delivery_id_b).  B's my_orders must include
#     delivery_id_b and must NOT include delivery_id_a.  A's my_orders must
#     include delivery_id_a and must NOT include delivery_id_b.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
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

# ── Step 3: A queries stores ──────────────────────────────────────────────────
rc, stores_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "stores" } },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "stores query failed (#{rc}): #{JSON.generate(stores_resp)}" unless rc == 200

stores = stores_resp.fetch("rows", [])
abort "no stores returned: #{JSON.generate(stores_resp)}" if stores.empty?
store_id = stores.first.fetch("id")

# ── Step 4: A queries products_by_store ───────────────────────────────────────
rc, prods_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "products_by_store", store_id: store_id } },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "products_by_store failed (#{rc}): #{JSON.generate(prods_resp)}" unless rc == 200

products = prods_resp.fetch("rows", [])
abort "no products returned for store #{store_id}" if products.empty?

in_stock_product     = products.find { |p| p["stock"].to_i > 0 }
out_of_stock_product = products.find { |p| p["stock"].to_i == 0 }
abort "no in-stock product found" unless in_stock_product
abort "no out-of-stock product found" unless out_of_stock_product

# ── Step 5: A adds in-stock product to cart ───────────────────────────────────
rc, add_in_stock = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:       "add_to_cart",
      store_id:   store_id,
      product_id: in_stock_product.fetch("id"),
      qty:        1,
    },
  },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A add_to_cart (in-stock) failed (#{rc}): #{JSON.generate(add_in_stock)}" unless rc == 200

cart_id_a             = add_in_stock.dig("value", "cart_id")
cart_item_id_in_stock = add_in_stock.dig("value", "cart_item_id")
abort "cart_id_a missing from add_to_cart response" unless cart_id_a

# ── Step 6: A adds out-of-stock product to same cart ─────────────────────────
rc, add_oos = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:       "add_to_cart",
      store_id:   store_id,
      product_id: out_of_stock_product.fetch("id"),
      qty:        1,
    },
  },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A add_to_cart (OOS) failed (#{rc}): #{JSON.generate(add_oos)}" unless rc == 200

cart_item_id_oos = add_oos.dig("value", "cart_item_id")
abort "cart_item_id_oos missing from add_to_cart OOS response" unless cart_item_id_oos

unless add_oos.dig("value", "cart_id") == cart_id_a
  abort "OOS add_to_cart returned different cart_id (#{add_oos.dig("value", "cart_id")}) than initial (#{cart_id_a})"
end

# ── Step 7: A queries substitution_options ────────────────────────────────────
rc, sub_opts = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "query",
    body: { name: "substitution_options", product_id: out_of_stock_product.fetch("id") },
  },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "substitution_options failed (#{rc}): #{JSON.generate(sub_opts)}" unless rc == 200

sub_rows = sub_opts.fetch("rows", [])
abort "no substitution options found for OOS product #{out_of_stock_product.fetch("id")}" if sub_rows.empty?
sub_product_id = sub_rows.first.fetch("suggested_product_id")

# ── Step 8: B tries apply_substitution on A's cart (MUST be 403) ─────────────
b_apply_sub_status, _b_apply_sub_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:                    "apply_substitution",
      cart_id:                 cart_id_a,
      cart_item_id:            cart_item_id_oos,
      substitution_product_id: sub_product_id,
      accept:                  true,
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)

# ── Step 9: B tries confirm_delivery on A's cart (MUST be 403) ───────────────
b_confirm_on_a_status, _b_confirm_on_a_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:             "confirm_delivery",
      cart_id:          cart_id_a,
      delivery_slot_id: 1,
      delivery_address: "2 Evil St, Istanbul",
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)

# ── Step 10: A confirms own delivery (MUST succeed) ───────────────────────────
rc, confirm_a = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:             "confirm_delivery",
      cart_id:          cart_id_a,
      delivery_slot_id: 2,
      delivery_address: "1 Good St, Istanbul",
    },
  },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A confirm_delivery failed (#{rc}): #{JSON.generate(confirm_a)}" unless rc == 200

delivery_id_a = confirm_a.dig("value", "delivery_id")
abort "delivery_id_a missing from confirm_delivery response" unless delivery_id_a

# ── Step 11: B queries my_orders before creating own delivery ─────────────────
rc, b_before_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (before) failed (#{rc}): #{JSON.generate(b_before_resp)}" unless rc == 200
b_my_orders_before = (b_before_resp["rows"] || []).map { |r| r["id"] }

# ── Step 12: B calls add_to_cart with forged user_id ─────────────────────────
rc, forged_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:       "add_to_cart",
      store_id:   store_id,
      product_id: in_stock_product.fetch("id"),
      qty:        1,
      user_id:    user_id_a,  # adversarial: B supplies A's user_id
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B forged add_to_cart failed (#{rc}): #{JSON.generate(forged_resp)}" unless rc == 200

cart_id_b_forged = forged_resp.dig("value", "cart_id")
abort "cart_id_b_forged missing from forged add_to_cart response" unless cart_id_b_forged

# ── Step 13: B creates own cart (genuine B) ───────────────────────────────────
rc, b_add_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:       "add_to_cart",
      store_id:   store_id,
      product_id: in_stock_product.fetch("id"),
      qty:        1,
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B add_to_cart (genuine) failed (#{rc}): #{JSON.generate(b_add_resp)}" unless rc == 200

cart_id_b = b_add_resp.dig("value", "cart_id")
abort "cart_id_b missing from B's genuine add_to_cart response" unless cart_id_b

# ── Step 14: B confirms own delivery ─────────────────────────────────────────
rc, b_confirm_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:             "confirm_delivery",
      cart_id:          cart_id_b,
      delivery_slot_id: 1,
      delivery_address: "3 Bob St, Istanbul",
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B confirm_delivery failed (#{rc}): #{JSON.generate(b_confirm_resp)}" unless rc == 200

delivery_id_b = b_confirm_resp.dig("value", "delivery_id")
abort "delivery_id_b missing from B's confirm_delivery response" unless delivery_id_b

# ── Step 15: B queries my_orders after creating own delivery ──────────────────
rc, b_after_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_orders (after) failed (#{rc}): #{JSON.generate(b_after_resp)}" unless rc == 200
b_my_orders_after = (b_after_resp["rows"] || []).map { |r| r["id"] }

# ── Step 16: A queries my_orders after B's positive control ───────────────────
rc, a_after_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A my_orders (after) failed (#{rc}): #{JSON.generate(a_after_resp)}" unless rc == 200
a_my_orders_after = (a_after_resp["rows"] || []).map { |r| r["id"] }

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:             user_id_a,
  user_id_b:             user_id_b,
  agent_id_a:            agent_id_a,
  agent_id_b:            agent_id_b,
  cart_id_a:             cart_id_a,
  cart_id_b:             cart_id_b,
  cart_id_b_forged:      cart_id_b_forged,
  delivery_id_a:         delivery_id_a,
  delivery_id_b:         delivery_id_b,
  b_apply_sub_status:    b_apply_sub_status,
  b_confirm_on_a_status: b_confirm_on_a_status,
  b_my_orders_before:    b_my_orders_before,
  b_my_orders_after:     b_my_orders_after,
  a_my_orders_after:     a_my_orders_after,
)
