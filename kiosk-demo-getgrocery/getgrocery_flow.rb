# frozen_string_literal: true

# Agent-side driver: no-human grocery order end-to-end.
# Flow: register → query catalog → run create_order → query delivery_slots
#       → pay → run schedule_delivery → query my_orders
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

# -- Step 2: query catalog --
rc_catalog, catalog_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "catalog" } },
  { "Authorization" => "Bearer #{token}" },
)
abort "query catalog failed (#{rc_catalog}): #{JSON.generate(catalog_resp)}" unless rc_catalog == 200
catalog = catalog_resp.fetch("rows", [])
abort "catalog returned empty rows" if catalog.empty?
STDERR.puts "  Catalog: #{catalog.size} in-stock products"

# Pick a few in-stock products (take first 3, or fewer if catalog has < 3)
items = catalog.first(3).map { |p| { sku: p.fetch("sku"), qty: 1 } }
STDERR.puts "  Ordering: #{items.map { |i| "sku=#{i[:sku]}" }.join(", ")}"

# -- Step 3: create_order --
rc_order, order_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "create_order", items: items } },
  { "Authorization" => "Bearer #{token}" },
)
abort "create_order failed (#{rc_order}): #{JSON.generate(order_resp)}" unless rc_order == 200
order_value = order_resp.fetch("value")
order_id    = order_value.fetch("order_id")
total_cents = order_value.fetch("total_cents")
STDERR.puts "  create_order: order_id=#{order_id} total=#{total_cents}c"

# -- Step 4: query delivery_slots --
delivery_date = (Date.today + 1).to_s
rc_slots, slots_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "delivery_slots", date: delivery_date } },
  { "Authorization" => "Bearer #{token}" },
)
abort "query delivery_slots failed (#{rc_slots}): #{JSON.generate(slots_resp)}" unless rc_slots == 200
slots = slots_resp.fetch("rows", [])
abort "delivery_slots returned empty" if slots.empty?
slot    = slots.first
slot_id = slot.fetch("id")
STDERR.puts "  Delivery slot: id=#{slot_id} #{slot["label"]} on #{delivery_date}"

# -- Step 5: pay --
now       = Time.now.to_i
intent_id = SecureRandom.uuid
cart_id   = SecureRandom.uuid

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
  id:                 cart_id,
  intent_mandate_id:  intent_id,
  user_id:            user_id,
  agent_id:           agent_id,
  iss:                ISSUER,
  line_items:         [{ order_id: order_id, total: total_cents }],
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

# -- Step 6: schedule_delivery --
rc_sched, sched_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "schedule_delivery",
                             order_id:         order_id,
                             delivery_slot_id: slot_id,
                             delivery_address: "42 Sakura Ave, Neo-Tokyo" } },
  { "Authorization" => "Bearer #{token}" },
)
abort "schedule_delivery failed (#{rc_sched}): #{JSON.generate(sched_resp)}" unless rc_sched == 200
sched_value  = sched_resp.fetch("value")
scheduled_at = sched_value.fetch("scheduled_at")
STDERR.puts "  schedule_delivery: order_id=#{order_id} scheduled=#{scheduled_at}"

# -- Step 7: query my_orders to confirm --
rc_my, my_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_orders" } },
  { "Authorization" => "Bearer #{token}" },
)
abort "my_orders failed (#{rc_my}): #{JSON.generate(my_resp)}" unless rc_my == 200
my_orders = my_resp.fetch("rows", [])
STDERR.puts "  my_orders: #{my_orders.size} order(s)"

# -- Step 8: print ONE JSON line --
puts JSON.generate(
  http_register:  rc_reg,
  http_catalog:   rc_catalog,
  http_order:     rc_order,
  http_slots:     rc_slots,
  http_pay:       rc_pay,
  http_schedule:  rc_sched,
  http_my_orders: rc_my,
  user_id:        user_id,
  agent_id:       agent_id,
  order_id:       order_id,
  total_cents:    total_cents,
  scheduled_at:   scheduled_at,
  my_orders:      my_orders,
  pay:            pay_resp,
)
