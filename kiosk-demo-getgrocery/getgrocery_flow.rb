# frozen_string_literal: true

# Agent-side driver: no-human grocery order end-to-end.
# Flow: register -> query stores -> query products_by_store -> run add_to_cart (x2)
#   -> query substitution_options -> run apply_substitution (accept: true)
#   -> query delivery_slots -> run confirm_delivery -> pay
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
#   bundle exec ruby getgrocery_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "date"
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

# -- Step 1: register (no PoW) --
key = OpenSSL::PKey::RSA.generate(2048)
rc_reg, reg = post_json(
  "#{SERVER}/kiosk/agents/register",
  { name: "hermes-grocery", public_key: key.public_key.to_pem, role: "customer" },
)
abort "register failed (#{rc_reg}): #{JSON.generate(reg)}" unless rc_reg == 201
agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")
STDERR.puts "  Registered: user_id=#{user_id}"

# -- Step 2: query stores --
rc_stores, stores_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "stores" } },
  { "Authorization" => "Bearer #{token}" },
)
abort "query stores failed (#{rc_stores}): #{JSON.generate(stores_resp)}" unless rc_stores == 200
stores = stores_resp.fetch("rows", [])
abort "stores returned empty rows" if stores.empty?
target_store = stores.first
store_id     = target_store.fetch("id")
STDERR.puts "  Stores: #{stores.size} found, using id=#{store_id} (#{target_store["name"]})"

# -- Step 3: query products_by_store --
rc_prods, prods_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "products_by_store", store_id: store_id } },
  { "Authorization" => "Bearer #{token}" },
)
abort "query products_by_store failed (#{rc_prods}): #{JSON.generate(prods_resp)}" unless rc_prods == 200
products = prods_resp.fetch("rows", [])
abort "products_by_store returned empty rows" if products.empty?
STDERR.puts "  Products: #{products.size} available"

# Pick an in-stock product for the first cart item
in_stock_product = products.find { |p| p["stock"].to_i > 0 }
abort "no in-stock product found" unless in_stock_product

# Pick an out-of-stock (or low-stock) product for substitution demo
out_of_stock_product = products.find { |p| p["stock"].to_i == 0 }
out_of_stock_product ||= products.find { |p| p["stock"].to_i <= 3 && p != in_stock_product }
abort "no low/out-of-stock product found for substitution demo" unless out_of_stock_product

STDERR.puts "  In-stock item: #{in_stock_product["sku"]} (stock=#{in_stock_product["stock"]})"
STDERR.puts "  Low/OOS item: #{out_of_stock_product["sku"]} (stock=#{out_of_stock_product["stock"]})"

# -- Step 4: add_to_cart (in-stock item) --
rc_add1, add1_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "add_to_cart", store_id: store_id,
                             product_id: in_stock_product.fetch("id"), qty: 2 } },
  { "Authorization" => "Bearer #{token}" },
)
abort "add_to_cart (in-stock) failed (#{rc_add1}): #{JSON.generate(add1_resp)}" unless rc_add1 == 200
cart_id = add1_resp.fetch("value").fetch("cart_id")
STDERR.puts "  add_to_cart(in-stock): cart_id=#{cart_id}"

# -- Step 5: add_to_cart (low/out-of-stock item) --
rc_add2, add2_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "add_to_cart", store_id: store_id,
                             product_id: out_of_stock_product.fetch("id"), qty: 1 } },
  { "Authorization" => "Bearer #{token}" },
)
abort "add_to_cart (low/OOS) failed (#{rc_add2}): #{JSON.generate(add2_resp)}" unless rc_add2 == 200
cart_item_id = add2_resp.fetch("value").fetch("cart_item_id")
STDERR.puts "  add_to_cart(low/OOS): cart_item_id=#{cart_item_id}"

# -- Step 6: query substitution_options --
rc_subs, subs_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "substitution_options",
                               product_id: out_of_stock_product.fetch("id") } },
  { "Authorization" => "Bearer #{token}" },
)
abort "query substitution_options failed (#{rc_subs}): #{JSON.generate(subs_resp)}" unless rc_subs == 200
sub_options = subs_resp.fetch("rows", [])
abort "no substitution options found for #{out_of_stock_product["sku"]}" if sub_options.empty?
sub_product_id = sub_options.first.fetch("suggested_product_id")
STDERR.puts "  Substitution: #{out_of_stock_product["sku"]} -> product_id=#{sub_product_id}"

# -- Step 7: apply_substitution (accept: true) --
rc_sub, sub_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "apply_substitution", cart_id: cart_id,
                             cart_item_id: cart_item_id,
                             substitution_product_id: sub_product_id,
                             accept: true } },
  { "Authorization" => "Bearer #{token}" },
)
abort "apply_substitution failed (#{rc_sub}): #{JSON.generate(sub_resp)}" unless rc_sub == 200
sub_value = sub_resp.fetch("value")
STDERR.puts "  apply_substitution: accepted=#{sub_value["accepted"]}, substituted=#{sub_value.dig("cart_item", "substituted")}"

# -- Step 8: query delivery_slots --
delivery_date = (Date.today + 1).to_s
rc_slots, slots_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "delivery_slots", date: delivery_date } },
  { "Authorization" => "Bearer #{token}" },
)
abort "query delivery_slots failed (#{rc_slots}): #{JSON.generate(slots_resp)}" unless rc_slots == 200
slots = slots_resp.fetch("rows", [])
abort "delivery_slots returned empty" if slots.empty?
slot = slots.first
slot_id = slot.fetch("id")
STDERR.puts "  Delivery slot: id=#{slot_id} #{slot["label"]} on #{delivery_date}"

# -- Step 9: confirm_delivery --
rc_confirm, confirm_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "confirm_delivery", cart_id: cart_id,
                             delivery_slot_id: slot_id,
                             delivery_address: "42 Bagdat Caddesi, Istanbul" } },
  { "Authorization" => "Bearer #{token}" },
)
abort "confirm_delivery failed (#{rc_confirm}): #{JSON.generate(confirm_resp)}" unless rc_confirm == 200
confirm_value = confirm_resp.fetch("value")
delivery_id   = confirm_value.fetch("delivery_id")
total_cents   = confirm_value.fetch("total_cents")
scheduled_at  = confirm_value.fetch("scheduled_at")
STDERR.puts "  confirm_delivery: delivery_id=#{delivery_id} total=#{total_cents}c scheduled=#{scheduled_at}"

# -- Step 10: pay --
now       = Time.now.to_i
intent_id = SecureRandom.uuid
pay_cart_id = SecureRandom.uuid

intent_payload = {
  id:               intent_id,
  user_id:          user_id,
  agent_id:         agent_id,
  iss:              ISSUER,
  scope:            "grocery",
  cap_amount_cents: total_cents + 200,
  currency:         "eur",
  exp:              now + 600,
  iat:              now,
}

cart_payload = {
  id:                 pay_cart_id,
  intent_mandate_id:  intent_id,
  user_id:            user_id,
  agent_id:           agent_id,
  iss:                ISSUER,
  line_items:         [{ delivery_id: delivery_id, total: total_cents }],
  total_amount_cents: total_cents,
  currency:           "eur",
  exp:                now + 600,
  iat:                now,
}

intent_jws = JWT.encode(intent_payload, key, "RS256")
cart_jws   = JWT.encode(cart_payload,   key, "RS256")

rc_pay, pay_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "pay", body: { intent_mandate_jws: intent_jws, cart_mandate_jws: cart_jws } },
  { "Authorization" => "Bearer #{token}" },
)
abort "pay failed (#{rc_pay}): #{JSON.generate(pay_resp)}" unless rc_pay == 200
STDERR.puts "  pay: mandate_id=#{pay_resp.dig("value", "payment_mandate_id")}"

# -- Step 11: print ONE JSON line --
puts JSON.generate(
  http_register:         rc_reg,
  http_stores:           rc_stores,
  http_products:         rc_prods,
  http_add_to_cart:      rc_add1,
  http_add_oos:          rc_add2,
  http_sub_options:      rc_subs,
  http_apply_sub:        rc_sub,
  http_delivery_slots:   rc_slots,
  http_confirm_delivery: rc_confirm,
  http_pay:              rc_pay,
  user_id:               user_id,
  agent_id:              agent_id,
  cart_id:               cart_id,
  delivery_id:           delivery_id,
  total_cents:           total_cents,
  scheduled_at:          scheduled_at,
  substitution_accepted: sub_value["accepted"],
  pay:                   pay_resp,
)
