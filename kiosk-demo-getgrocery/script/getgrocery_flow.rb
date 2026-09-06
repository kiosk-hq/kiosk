# frozen_string_literal: true

# Agent-side driver: no-human grocery order end-to-end.
# Flow: register → GET catalog → GET delivery_slots (delivery ADDRESS/zone is
#         a REQUIRED early input, validated against served Dublin districts — an
#         out-of-zone / district-less address → clean 400, asserted here)
#       → POST create_order (items + delivery slot + in-zone address — delivery
#         is part of the order) → POST payment_setup (verify "ready") → POST pay
#         (cart mirrors the order at catalog prices, EUR; off_session → real pi_…)
#       → GET my_orders (own order present, payment_state: "paid")
# Runs with KIOSK_TEST_AUTOCARD=1: the adapter simulates a completed SetupIntent,
# so there is no card-setup step (the live flow uses the real hosted page).
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3001 \
#   KIOSK_ISSUER=http://127.0.0.1:3001 \
#   bundle exec ruby script/getgrocery_flow.rb
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

# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the QUERY STRING; an action is `POST <endpoint>/<action-name>` with its
# arguments as the JSON BODY. There is no `name` field and no /query or /run
# endpoint. A success body IS the result — a bare array from a non-paginating
# query, the action's own object from an action, the settlement object from
# `pay` — and an error is an RFC 9457 problem document whose branch point is
# the TOP-LEVEL `code` (`message` is now `detail`).
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

# -- Step 1: register (proof-of-possession handshake, + register PoW) --
# A public key is not a credential — it's public. Prove control of the PRIVATE
# key: fetch a single-use challenge, sign it with `aud` = the origin we dialed
# (so the proof can't be relayed to another provider), then register. Register
# is tolled: the helper solves the Equihash register PoW and resubmits — the
# SAME private key is returned so it can sign the payment mandates below.
require_relative "equihash_register"
key, reg, rc_register = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")
STDERR.puts "  Registered: user_id=#{user_id}"

# NOTE: no card-setup step here. This runs with KIOSK_TEST_AUTOCARD=1 (set by the
# rake task), so the Stripe adapter simulates a completed SetupIntent at capture —
# payment_setup returns {status:"ready"} and pay runs off_session. In production /
# the live demo the human completes the real hosted SetupIntent once instead.

# -- Step 2: query catalog --
rc_catalog, catalog_resp = get_json(
  "#{SERVER}/kiosk/catalog",
  { "Authorization" => "Bearer #{token}" },
)
abort "query catalog failed (#{rc_catalog}): #{JSON.generate(catalog_resp)}" unless rc_catalog == 200
catalog = Array(catalog_resp)
abort "catalog returned empty rows" if catalog.empty?
abort "catalog rows must carry currency=eur" unless catalog.all? { |p| p["currency"] == "eur" }
abort "catalog rows must carry a price_eur display string" unless catalog.all? { |p| p["price_eur"].to_s.start_with?("€") }
STDERR.puts "  Catalog: #{catalog.size} in-stock products (EUR)"

# Pick a few in-stock products (take first 3, or fewer if catalog has < 3).
# Keep the full rows — the cart mandate must mirror them at catalog prices.
chosen = catalog.first(3)
items  = chosen.map { |p| { sku: p.fetch("sku"), qty: 1 } }
STDERR.puts "  Ordering: #{items.map { |i| "sku=#{i[:sku]}" }.join(", ")}"

# -- Step 3: query delivery_slots (delivery ADDRESS/zone is a REQUIRED early input) --
# ADDRESS-UPFRONT: the address must name a SERVED Dublin district or the
# operator returns 400 before it will show any slots. This is a real, in-zone
# Dublin address; in a live run the ASSISTANT obtains it from its human (never
# invents one) — the operator validates zone/format but cannot verify it is real.
# Query for TODAY (the live-run scenario) so the assertion below catches any
# date drift — create_order must book the SAME day the slot was shown for, not
# a fixed +1.
# delivery_slots hides today's already-started windows. If this runs
# late enough in Dublin's day that today is sold out, fall back to tomorrow so
# the happy-path proof is robust to wall-clock time; the no-drift assertion below
# copies whatever date the returned row carries, so it holds for either day.
delivery_address = "42 Camden Street, Dublin 2"
delivery_date    = Date.today.to_s

# Negative control: an out-of-zone / district-less address → clean 400 (bad_request),
# NOT a 500. Proves the address gate rejects gross fakes with a clear message.
rc_bad, bad_resp = get_json(
  "#{SERVER}/kiosk/delivery_slots",
  { "Authorization" => "Bearer #{token}" },
  { date: delivery_date, delivery_address: "123 Demo Street, Dublin" },
)
bad_code = bad_resp["code"]
abort "out-of-zone delivery_slots expected 400 bad_request, got #{rc_bad} #{bad_code.inspect}" \
  unless rc_bad == 400 && bad_code == "bad_request"
STDERR.puts "  delivery_slots (district-less address): http=#{rc_bad} code=#{bad_code} (rejected, as expected)"

rc_slots = nil
# NO DATE IS SENT, and that is the whole point. This client cannot know what
# day it is at the shop -- getgrocery delivers in Europe/Dublin, so between
# 23:00 and 00:00 UTC its today and ours are different dates. Omitting `date`
# asks for the soonest day it can deliver and is correct at every hour.
#
# An earlier version of this file sent Date.today and RETRIED when the operator
# refused it as past. That worked and was still wrong: a retry is a second
# round trip to learn something the operator could have been asked properly the
# first time, and a reference driver is what an assistant copies. The verb now
# makes `date` optional, so the round trip is gone rather than handled.
query_slots = lambda do |date_str|
  args = { delivery_address: delivery_address }
  args[:date] = date_str if date_str
  rc_slots, resp = get_json(
    "#{SERVER}/kiosk/delivery_slots",
    { "Authorization" => "Bearer #{token}" },
    args,
  )
  abort "query delivery_slots failed (#{rc_slots}): #{JSON.generate(resp)}" unless rc_slots == 200
  Array(resp)
end

slots = query_slots.call(nil)
# The rows carry the day the operator picked -- that is how a caller that
# omitted the date learns which day it got, and create_order must book that
# same day. There is no sold-out fallback here any more: "soonest" already
# means the soonest day with windows left, so an empty answer would be a
# defect in the operator rather than a case for the client to handle.
delivery_date = slots.first["date"] if slots.any?
abort "delivery_slots returned empty" if slots.empty?
abort "delivery_slots rows must carry the resolved zone" unless slots.all? { |s| s["zone"].to_s.start_with?("D") }
slot          = slots.first
slot_id       = slot.fetch("delivery_slot_id")
slot_date     = slot.fetch("date")     # the day the assistant sees for this slot
chosen_slot_at = slot.fetch("slot_at") # its exact start time — create_order must match
STDERR.puts "  Delivery slot: id=#{slot_id} #{slot["label"]} zone=#{slot["zone"]} on #{slot_date} (#{chosen_slot_at})"

# Negative control: delivery_slots must HIDE already-started windows, and
# create_order must REJECT one with a clean 400 (never book an un-bookable past
# slot). This only asserts when there genuinely is a past slot for the queried
# day — i.e. some early slot id (1..6) is absent from the returned set because
# its start has already passed in Dublin. (When we're booking tomorrow, or it's
# before 08:00 Dublin, no slot is past and this control is a no-op.)
returned_ids   = slots.map { |s| s["delivery_slot_id"].to_i }
missing_ids     = (1..6).to_a - returned_ids
past_slot_check = nil
unless missing_ids.empty?
  past_id = missing_ids.min
  rc_past, past_resp = post_json(
    "#{SERVER}/kiosk/create_order",
    { items: items,
      delivery_slot_id: past_id,
      delivery_date:    slot_date,
      delivery_address: delivery_address },
    { "Authorization" => "Bearer #{token}" },
  )
  past_code = past_resp["code"]
  abort "K-480: create_order on a PAST slot (#{past_id} on #{slot_date}) expected 400 bad_request, got #{rc_past} #{past_code.inspect}" \
    unless rc_past == 400 && past_code == "bad_request"
  past_slot_check = { id: past_id, http: rc_past, code: past_code }
  STDERR.puts "  K-480: create_order on past slot id=#{past_id} → http=#{rc_past} code=#{past_code} (rejected, as expected)"
end

# -- Step 4: create_order (items + delivery slot + chosen slot's date + address) --
# Pass back the DATE of the slot we chose so create_order books the day
# we saw, not a fixed +1.
rc_order, order_resp = post_json(
  "#{SERVER}/kiosk/create_order",
  { items: items,
    delivery_slot_id: slot_id,
    delivery_date:    slot_date,
    delivery_address: delivery_address },
  { "Authorization" => "Bearer #{token}" },
)
abort "create_order failed (#{rc_order}): #{JSON.generate(order_resp)}" unless rc_order == 200
# An action's success body IS its own object — there is no `value` to unwrap.
order_value = order_resp
order_id    = order_value.fetch("order_id")
total_cents = order_value.fetch("total_cents")
slot_at     = order_value.fetch("slot_at")
# The booked slot_at MUST equal the date+start-time of the slot the agent
# saw and chose in delivery_slots — same day, NOT +1.
abort "K-470: create_order slot_at=#{slot_at.inspect} != chosen delivery_slot slot_at=#{chosen_slot_at.inspect} (date drift)" \
  unless slot_at == chosen_slot_at
abort "create_order result must carry currency=eur" unless order_value["currency"] == "eur"
abort "create_order result must carry a total_eur display string" unless order_value["total_eur"].to_s.start_with?("€")
abort "create_order result must carry a pay_hint" if order_value["pay_hint"].to_s.empty?
STDERR.puts "  create_order: order_id=#{order_id} total=#{order_value["total_eur"]} slot_at=#{slot_at}"

# -- Step 5: payment_setup (verify card is on file before paying) --
# In the live flow an assistant calls this before every pay; if setup_required,
# it hands the human the setup_url. Under KIOSK_TEST_AUTOCARD the provider
# reports {status:"ready"} (card auto-provisioned at capture).
rc_setup, setup_resp = post_json(
  "#{SERVER}/kiosk/payment_setup",
  {},
  { "Authorization" => "Bearer #{token}" },
)
abort "payment_setup failed (#{rc_setup}): #{JSON.generate(setup_resp)}" unless rc_setup == 200
setup_status = setup_resp["status"]
abort "payment_setup status expected 'ready', got #{setup_status.inspect}" unless setup_status == "ready"
STDERR.puts "  payment_setup: #{setup_status}"

# -- Step 6: pay --
# The cart MIRRORS the order per create_order's pay_hint: one {order_id}
# entry plus one {sku, qty, price_cents} entry per item at catalog prices.
# The operator (ValidatingPaymentProvider) verifies currency, prices, and
# total against its catalog before capturing.
now        = Time.now.to_i
intent_id  = SecureRandom.uuid
cart_id    = SecureRandom.uuid
payment_id = SecureRandom.uuid

mirror_lines = chosen.map { |p| { sku: p.fetch("sku"), qty: 1, price_cents: p.fetch("price_cents").to_i } }
mirror_sum   = mirror_lines.sum { |l| l[:qty] * l[:price_cents] }
abort "mirror sum #{mirror_sum} != server total #{total_cents}" unless mirror_sum == total_cents.to_i

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
  line_items:         [{ order_id: order_id }] + mirror_lines,
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
  # No payment_method: SetupIntent model — the provider's Stripe adapter
  # resolves the principal's on-file card; the assistant never presents one.
  # The server persists "on_file" as an audit sentinel.
  amount_cents:    total_cents,
  currency:        "eur",
  exp:             now + 600,
  iat:             now,
}

intent_jws  = JWT.encode(intent_payload,  key, "RS256")
cart_jws    = JWT.encode(cart_payload,    key, "RS256")
payment_jws = JWT.encode(payment_payload, key, "RS256")

rc_pay, pay_resp = post_json(
  "#{SERVER}/kiosk/pay",
  { intent_mandate_jws: intent_jws, cart_mandate_jws: cart_jws,
    payment_mandate_jws: payment_jws },
  { "Authorization" => "Bearer #{token}" },
)
abort "pay failed (#{rc_pay}): #{JSON.generate(pay_resp)}" unless rc_pay == 200
# `POST /kiosk/pay` keeps its path; its SUCCESS body is the SETTLEMENT OBJECT
# itself — {settlement_id, psp_reference, settled_amount_cents, currency} — not
# a `{ok, kind, value}` wrapper.
psp_ref = pay_resp["psp_reference"].to_s
abort "pay: psp_reference expected 'pi_…' (real Stripe), got #{psp_ref.inspect}" unless psp_ref.start_with?("pi_")
STDERR.puts "  pay: settlement_id=#{pay_resp["settlement_id"]} psp_reference=#{psp_ref}"

# -- Step 7: query my_orders to confirm (own order present, paid) --
rc_my, my_resp = get_json(
  "#{SERVER}/kiosk/my_orders",
  { "Authorization" => "Bearer #{token}" },
)
abort "my_orders failed (#{rc_my}): #{JSON.generate(my_resp)}" unless rc_my == 200
my_orders = Array(my_resp)
own = my_orders.find { |o| o["order_id"] == order_id }
abort "my_orders does not contain own order #{order_id}" if own.nil?
# The wire field is a TRI-state (unpaid | pending | paid), not a boolean.
# `paid` is the only one of the three that means the charge went through; a
# `pending` here would mean a capture is still outstanding, which is NOT a
# settled order and must not be read as one.
payment_state = own["payment_state"]
abort "my_orders own order not marked paid: #{own.inspect}" unless payment_state == "paid"
STDERR.puts "  my_orders: #{my_orders.size} order(s); own order payment_state=paid"

# -- Step 8: print ONE JSON line --
puts JSON.generate(
  http_register:      rc_register,

  http_catalog:       rc_catalog,
  http_slots:         rc_slots,
  http_slots_badzone: rc_bad,
  slots_badzone_code: bad_code,
  http_order:         rc_order,
  http_payment_setup: rc_setup,
  http_pay:           rc_pay,
  http_my_orders:     rc_my,
  user_id:            user_id,
  agent_id:           agent_id,
  order_id:           order_id,
  total_cents:        total_cents,
  slot_at:            slot_at,
  chosen_slot_at:     chosen_slot_at,
  slot_date:          slot_date,
  past_slot_check:    past_slot_check,
  payment_state:      payment_state,
  psp_reference:      psp_ref,
  my_orders:          my_orders,
  pay:                pay_resp,
)
