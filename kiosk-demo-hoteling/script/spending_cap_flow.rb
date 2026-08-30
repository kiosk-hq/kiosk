# frozen_string_literal: true
#
# Agent-side driver: the PER-ASSISTANT SPENDING CAP, and the one property that
# makes it a cap rather than a suggestion — that two spellings of one ISO 4217
# code are ONE tally (T-154, from K-1251).
#
# WHY THIS EXISTS. `config.spending_cap` is a pay-path control the engine has
# shipped for months, and until this driver NO demo and NO e2e origin
# configured it: `git grep -nE "\.spending_cap[[:space:]]*=" -- 'kiosk-demo-*'
# 'e2e'` found one COMMENT and no assignment, so `Executor#enforce_spending_cap!`
# returned at its first line everywhere in the fleet. That is exactly what let
# K-1251 sit unnoticed — a cap defeatable by capitalisation, live for any
# operator who configured the control and for nobody here. The fix has a gem
# suite behind it (SPEC-186) and, until now, nothing that BOOTS.
#
# WHAT IT PROVES, in one chain, against a real origin with a real Equihash
# registration and the shipped ValidatingBookingProvider:
#
#   1. a spend UNDER the cap settles;
#   2. a spend that would CROSS it is refused `403 spending_cap_exceeded`,
#      with nothing persisted and nothing captured;
#   3. THE K-1251 PROPERTY — the crossing spend is spelled "EUR" while the
#      settled one was "eur". A byte-scoped tally sees an empty history for
#      "EUR" and lets the charge through; the folded tally counts it against
#      the same cap. So step 2 going red IS the regression detector, and it is
#      the reason the two spends are deliberately spelled differently;
#   4. it was the CAP and only the cap: raising the cap by one cent and
#      re-signing the SAME "EUR" chain settles it, so the refusal cannot be
#      "this operator rejects that spelling";
#   5. the settled rows are CANONICAL — both say "eur" whatever was signed —
#      which is the boundary half of the fix, asserted on disk by the task.
#
# The cap itself is written with `psql`, the way the operator's own
# manage-assistants page would write it (`agents.spending_cap_cents`, which
# `Kiosk::Server::ColumnSpendingCap` reads): the column is the seam, and there
# is no HTTP surface on THIS demo for a human to set it through.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3003 KIOSK_ISSUER=http://127.0.0.1:3003 \
#     HOTELING_DB=kiosk_hoteling_development bundle exec ruby script/spending_cap_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any unexpected failure.

require "date"
require "jwt"
require "json"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")
DB     = ENV.fetch("HOTELING_DB", "kiosk_hoteling_development")

# A window of its own, well clear of script/hoteling_flow.rb's today+30..+33.
# `demo:book` takes that property's whole inventory for those nights and the
# unpaid hold is never released (K-936, K-1044); a driver that shared the
# window would inherit that exhaustion for no reason.
CHECK_IN  = (Date.today + 90).to_s
CHECK_OUT = (Date.today + 92).to_s
NIGHTS    = (Date.parse(CHECK_OUT) - Date.parse(CHECK_IN)).to_i

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

def query_json(name, params = {}, headers = {})
  uri = URI("#{SERVER}/kiosk/#{name}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  get_json(uri.to_s, headers)
end

# Write the assistant's cap the way the operator would — into the column the
# engine's batteries-included seam reads. The id is asserted to be a uuid
# BEFORE it reaches the statement: it comes from the wire, and a value from the
# wire never goes into SQL text on trust (K-654's rule, applied to a driver).
def set_cap!(agent_id, cents)
  unless agent_id =~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    abort "refusing to write a cap for a non-uuid agent_id #{agent_id.inspect}"
  end

  out = `psql -X -d #{DB} -tAc "UPDATE kiosk.agents SET spending_cap_cents = #{Integer(cents)} WHERE id = '#{agent_id}'" 2>&1`.strip
  abort "cap write failed (#{out.inspect})" unless out == "UPDATE 1"
  STDERR.puts "  Operator set the assistant's cap to #{format("€%.2f", cents / 100.0)}"
end

# Sign and submit one AP2 chain for `booking`, denominated in `currency`
# VERBATIM — the spelling is the subject of this driver, so it is never
# normalised on the way out.
def pay(booking, currency:, key:, token:, user_id:, agent_id:)
  now   = Time.now.to_i
  total = booking.fetch(:total_cents)
  ids   = { intent: SecureRandom.uuid, cart: SecureRandom.uuid, payment: SecureRandom.uuid }

  intent = {
    id: ids[:intent], user_id: user_id, agent_id: agent_id, iss: ISSUER,
    scope: "lodging", cap_amount_cents: total + 100, currency: currency,
    exp: now + 600, iat: now,
  }
  cart = {
    id: ids[:cart], intent_mandate_id: ids[:intent], user_id: user_id, agent_id: agent_id,
    iss: ISSUER,
    line_items: [{ sku: booking.fetch(:room_type_name), qty: NIGHTS,
                   price_cents: booking.fetch(:nightly_price_cents),
                   booking_id: booking.fetch(:booking_id) }],
    total_amount_cents: total, currency: currency, exp: now + 600, iat: now,
  }
  payment = {
    id: ids[:payment], cart_mandate_id: ids[:cart], user_id: user_id, agent_id: agent_id,
    iss: ISSUER, payment_method: "pm_demo", amount_cents: total, currency: currency,
    exp: now + 600, iat: now,
  }

  post_json(
    "#{SERVER}/kiosk/pay",
    { intent_mandate_jws:  JWT.encode(intent,  key, "RS256"),
      cart_mandate_jws:    JWT.encode(cart,    key, "RS256"),
      payment_mandate_jws: JWT.encode(payment, key, "RS256") },
    { "Authorization" => "Bearer #{token}" },
  )
end

results = {}

# ── Step 1: register (the toll is solved transparently) ─────────────────────
require_relative "equihash_register"
key, reg, rc_register = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")
results[:http_register] = rc_register
results[:agent_id]      = agent_id
results[:user_id]       = user_id
STDERR.puts "  Registered: agent_id=#{agent_id} user_id=#{user_id}"

# ── Step 2: find a property with TWO bookable room types in our window ──────
#
# Walked rather than assumed. Most seeded properties carry two or three room
# types, but "most" is not a property a gate may rest on, and a driver that
# aborted with «availability returned empty rows» on the second reservation
# would name the wrong cause entirely.
rc_props, props_resp = query_json("properties", {}, { "Authorization" => "Bearer #{token}" })
abort "query properties failed (#{rc_props}): #{JSON.generate(props_resp)}" unless rc_props == 200
results[:http_properties] = rc_props

property_id = nil
rooms       = nil
Array(props_resp).each do |prop|
  rc_avail, avail = query_json(
    "availability",
    { property_id: prop.fetch("property_id"), check_in: CHECK_IN, check_out: CHECK_OUT },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "query availability failed (#{rc_avail}): #{JSON.generate(avail)}" unless rc_avail == 200
  next unless Array(avail).size >= 2

  property_id = prop.fetch("property_id")
  rooms       = Array(avail).first(2)
  STDERR.puts "  Using #{prop["name"]} (#{property_id}) — #{rooms.map { |r| r["name"] }.join(" + ")}"
  break
end
abort "no seeded property offers two room types for #{CHECK_IN}..#{CHECK_OUT}" if rooms.nil?

# ── Step 3: reserve both, so the operator has QUOTED both totals ────────────
bookings = rooms.map do |room|
  rc, rsv = post_json(
    "#{SERVER}/kiosk/reserve_room",
    { property_id: property_id, room_type_id: room.fetch("room_type_id"),
      check_in: CHECK_IN, check_out: CHECK_OUT },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "reserve_room failed (#{rc}): #{JSON.generate(rsv)}" unless rc == 200
  { booking_id: rsv.fetch("booking_id"), total_cents: rsv.fetch("total_cents").to_i,
    room_type_name: room.fetch("name"), nightly_price_cents: room.fetch("nightly_price_cents").to_i }
end
first, second = bookings
results[:first_total_cents]  = first.fetch(:total_cents)
results[:second_total_cents] = second.fetch(:total_cents)

# ── Step 4: the cap — ONE CENT below what the two stays cost together ───────
#
# Chosen from the operator's OWN quotes rather than written down, so the
# arithmetic below is true whatever the seeded prices are: the first stay fits,
# the two together do not, and under a BYTE-SCOPED tally the second would fit
# as well (its "EUR" history would be empty, and T2 <= T1 + T2 - 1 for any
# T1 >= 1). That is the whole regression detector, and it is why the two spends
# are spelled differently on purpose.
cap = first.fetch(:total_cents) + second.fetch(:total_cents) - 1
results[:cap_cents] = cap
set_cap!(agent_id, cap)

# ── Step 5: UNDER the cap, spelled "eur" — settles ──────────────────────────
rc, resp = pay(first, currency: "eur", key: key, token: token, user_id: user_id, agent_id: agent_id)
results[:http_pay_under_cap]     = rc
results[:pay_under_cap_currency] = resp["currency"]
abort "the under-cap charge did not settle (#{rc}): #{JSON.generate(resp)}" unless rc == 200
STDERR.puts "  Under the cap: settled #{format("€%.2f", first.fetch(:total_cents) / 100.0)} as \"eur\""

# ── Step 6: OVER the cap, spelled "EUR" — must be refused ───────────────────
rc, resp = pay(second, currency: "EUR", key: key, token: token, user_id: user_id, agent_id: agent_id)
results[:http_pay_over_cap] = rc
results[:pay_over_cap_code] = resp["code"]
results[:pay_over_cap_hint] = resp["hint"]
STDERR.puts "  Over the cap, spelled \"EUR\": HTTP #{rc} #{resp["code"].inspect}"

# ── Step 7: raise the cap by ONE CENT and re-sign the SAME chain ────────────
#
# The control for step 6. Without it, "EUR was refused" is consistent with an
# operator that simply rejects the upper-case spelling — which this one does
# NOT (ValidatingBookingProvider downcases before it compares), but a beat that
# cannot tell the two apart is not evidence. Nothing was persisted by the
# refusal (the cap is checked before phase 1 writes anything and before the
# capture), so the booking is still `unpaid` and payable.
#
# RUN ONLY IF STEP 6 WAS ACTUALLY REFUSED, and that is not defensive coding: if
# the cap were bypassed, the second stay would already be PAID, this re-pay
# would be refused for being a second charge on a settled booking, and the
# driver would abort naming the wrong thing entirely. Recording the skip lets
# the task's own `http_pay_over_cap == 403` assertion be the line that goes red.
if results[:http_pay_over_cap] == 403
  set_cap!(agent_id, cap + 1)
  rc, resp = pay(second, currency: "EUR", key: key, token: token, user_id: user_id, agent_id: agent_id)
  results[:http_pay_after_raise]     = rc
  results[:pay_after_raise_currency] = resp["currency"]
  abort "the same \"EUR\" chain did not settle once the cap allowed it (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  STDERR.puts "  Cap raised by one cent: the SAME \"EUR\" chain settled"
else
  results[:http_pay_after_raise]     = "skipped — the over-cap charge was not refused"
  results[:pay_after_raise_currency] = nil
  STDERR.puts "  Skipping the cap-raise control: the over-cap charge was not refused, so there is " \
              "nothing to control for"
end

puts JSON.generate(results)
