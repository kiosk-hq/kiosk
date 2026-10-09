# frozen_string_literal: true

# Red-team battery for getgrocery: attacks a running server and asserts every attack is refused.
# Usage: SERVER_URL=http://127.0.0.1:3001 bundle exec ruby script/redteam_suite.rb

require "date"
require "json"
require "kiosk/redteam"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

# The day every order here is booked on: tomorrow, so every window is open.
ORDER_DAY = (Date.today + 1).iso8601

BASE_URL = ENV.fetch("SERVER_URL")
ISSUER   = BASE_URL

profile = Kiosk::Redteam::Profile.new(
  # Register PoW is on; only "> 0" matters, the server's 402 challenges set the real difficulty.
  pow_difficulty: 1,
  requires_kyc:   false,

  currency:       "eur",
  declared_roles: %w[customer],
  per_user_query: "my_orders",

  result_id_key: "order_id",
  row_id_key:    "order_id",

  # The items are kept so pay_for can mirror the order at catalog prices (the cashier check).
  create_owned: ->(client, principal) {
    catalog_resp = client.query(principal, name: "catalog")
    # A non-paginating query answers a BARE ARRAY — there is no `rows` to unwrap.
    catalog = catalog_resp.body.is_a?(Array) ? catalog_resp.body : []
    raise "redteam: catalog returned empty" if catalog.empty?
    product = catalog.first

    order_resp = client.run(
      principal,
      name:             "create_order",
      items:            [{ sku: product["sku"], qty: 1 }],
      delivery_slot_id: 1, delivery_date: ORDER_DAY,
      delivery_address: "1 Redteam St, Dublin 1",
    )
    raise "redteam: create_order failed (#{order_resp.status}): #{order_resp.body.inspect}" \
      unless order_resp.status == 200

    order_id    = order_resp.body["order_id"]
    total_cents = order_resp.body["total_cents"].to_i
    raise "redteam: create_order missing order_id" unless order_id

    {
      id:          order_id,
      total_cents: total_cents,
      items:       [{ sku: product["sku"], qty: 1, price_cents: product["price_cents"].to_i }],
    }
  },

  forge_action: "create_order",
  forge_args: ->(client, _principal_a, _principal_b) {
    catalog_resp = client.query(_principal_b, name: "catalog")
    catalog = catalog_resp.body.is_a?(Array) ? catalog_resp.body : []
    raise "redteam: catalog empty for forge_args" if catalog.empty?
    product = catalog.first
    {
      items:            [{ sku: product["sku"], qty: 1 }],
      delivery_slot_id: 1, delivery_date: ORDER_DAY,
      delivery_address: "1 Redteam St, Dublin 1",
    }
  },

  # One reschedule per order: the second attempt is the spent-resource beat.
  gated_action: "reschedule_delivery",
  gated_args:   ->(owned_ref) {
    {
      order_id:         owned_ref[:id],
      delivery_slot_id: 2, delivery_date: ORDER_DAY,
    }
  },

  # No card-setup step: KIOSK_TEST_AUTOCARD=1 against stripe-mock provisions a test card at capture.
  pay_for: ->(_client, principal, owned_ref) {
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    cart_id   = SecureRandom.uuid

    total_cents      = owned_ref[:total_cents].to_i
    cap_amount_cents = total_cents + 200

    intent = {
      id:               intent_id,
      user_id:          principal.user_id,
      agent_id:         principal.agent_id,
      iss:              ISSUER,
      scope:            "grocery",
      cap_amount_cents: cap_amount_cents,
      currency:         "eur",
      exp:              now + 600,
      iat:              now,
    }

    cart = {
      id:                 cart_id,
      intent_mandate_id:  intent_id,
      user_id:            principal.user_id,
      agent_id:           principal.agent_id,
      iss:                ISSUER,
      line_items:         [{ order_id: owned_ref[:id] }] + (owned_ref[:items] || []),
      total_amount_cents: total_cents,
      currency:           "eur",
      exp:                now + 600,
      iat:                now,
    }

    { intent: intent, cart: cart }
  },

  kyc_valid:   nil,
  kyc_expired: nil,
  kyc_forged:  nil,
)

# A below-catalog line price, with total and cap kept chain-consistent.
class TamperedPriceCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "TamperedPriceCart",
      category:    "payment",
      description: "A cart whose line price differs from the catalog must be rejected at capture",
    )
  end

  def call(client, profile)
    a = client.register!
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)

    tampered_items = (owned[:items] || []).map.with_index do |li, i|
      i.zero? ? li.merge(price_cents: li[:price_cents].to_i - 50) : li
    end
    tampered_total = tampered_items.sum { |li| li[:qty].to_i * li[:price_cents].to_i }
    m[:cart] = m[:cart].merge(
      line_items:         [{ order_id: owned[:id] }] + tampered_items,
      total_amount_cents: tampered_total,
    )
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    # 403 exactly: a 401 would mean the cashier never priced this cart.
    verdict_from(resp, expect: 403, detail: "below-catalog line price settled (HTTP #{resp.status})")
  end
end

class InflatedTotalCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "InflatedTotalCart",
      category:    "payment",
      description: "A cart whose total exceeds the sum of its lines must be rejected at capture",
    )
  end

  def call(client, profile)
    a = client.register!
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)
    m[:cart] = m[:cart].merge(total_amount_cents: owned[:total_cents].to_i + 100)
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    verdict_from(resp, expect: 403, detail: "total above the order's catalog sum settled (HTTP #{resp.status})")
  end
end

class MalformedItemsCart < Kiosk::Redteam::Scenario
  ADDRESS = "1 Redteam St, Dublin 1"
  RUBY_INTERNALS = ["NoMethodError", "TypeError", "undefined method", "no implicit conversion"].freeze

  BAD_ITEMS = [
    ["a String",             "sourdough-bread"],
    ["a Hash (one item, unwrapped)", { sku: "sourdough-bread", qty: 1 }],
    ["an array of Strings",  ["sourdough-bread"]],
    ["an array of Integers", [1, 2]],
    ["an Integer",           5],
    ["an array with null",   [nil]],
    ["an empty array",       []],
    ["absent",               nil],
  ].freeze

  def initialize
    super(
      name:        "MalformedItemsCart",
      category:    "input",
      description: "A non-array (or non-object-element) `items` must be a typed 400, never a 500",
    )
  end

  def call(client, profile)
    a        = client.register!
    failures = []
    statuses = []

    BAD_ITEMS.each do |label, items|
      args = { delivery_slot_id: 1, delivery_date: ORDER_DAY, delivery_address: ADDRESS }
      args[:items] = items unless items.nil?
      resp = client.run(a, name: "create_order", **args)
      statuses << resp.status
      code = resp.body.is_a?(Hash) ? resp.body["code"] : nil
      # The refusal may echo the probe's own bytes, so the scan is told what was sent.
      scan = Kiosk::Redteam::LeakScan.scan(resp.body, RUBY_INTERNALS, supplied: args)
      next if resp.status == 400 && code == "bad_request" && !scan.leak?

      failures << "items #{label} → HTTP #{resp.status} code=#{code.inspect}" \
                  "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
    end

    # Control: a well-formed cart still places an order.
    catalog_body = client.query(a, name: "catalog").body
    catalog = catalog_body.is_a?(Array) ? catalog_body : []
    control = client.run(a, name: "create_order",
                            items: [{ sku: catalog.first["sku"], qty: 1 }],
                            delivery_slot_id: 1, delivery_date: ORDER_DAY, delivery_address: ADDRESS)
    statuses << control.status
    unless control.status == 200
      failures << "CONTROL well-formed items → HTTP #{control.status} #{control.body.inspect} (want 200)"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: failures.empty?,
      skipped: false,
      status:  statuses.find { |s| s != 400 && s != 200 } || 400,
      detail:  failures.join(" | "),
    )
  end
end

# Hostile shapes on create_order's scalar arguments, items[].qty, and reschedule_delivery's order_id.
class HostileArgShapes < Kiosk::Redteam::Scenario
  ADDRESS = "2 Redteam Row, Dublin 2"

  LEAKS = ["NoMethodError", "TypeError", "undefined method", "no implicit conversion",
           "::uuid", "PG::", "22P02", "invalid input syntax", "ActiveRecord::"].freeze

  SHAPES = [true, false, [], {}, [1], { "a" => 1 }, "abc", 1.5].freeze

  def initialize
    super(
      name:        "HostileArgShapes",
      category:    "input",
      description: "Boolean/array/object/junk values on items[].qty, delivery_slot_id, delivery_date, delivery_address and order_id are a typed 400 — never a 500",
    )
  end

  def call(client, profile)
    a         = client.register!
    @failures = []
    catalog   = client.query(a, name: "catalog").body
    raise "redteam(getgrocery): empty catalog" unless catalog.is_a?(Array) && catalog.any?

    good_items = [{ sku: catalog.first["sku"], qty: 1 }]

    SHAPES.each do |v|
      refused "create_order delivery_slot_id=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: v, delivery_date: ORDER_DAY, delivery_address: ADDRESS),
              supplied: v
      refused "reschedule_delivery order_id=#{v.inspect}",
              client.run(a, name: "reschedule_delivery", order_id: v, delivery_slot_id: 1, delivery_date: ORDER_DAY),
              supplied: v
    end
    # Outside the declared slot range 1..6.
    [0, -1, 7, 999].each do |v|
      refused "create_order delivery_slot_id=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: v, delivery_date: ORDER_DAY, delivery_address: ADDRESS),
              supplied: v
    end

    sku = catalog.first["sku"]
    (SHAPES + [0, -1]).each do |v|
      refused "create_order items[0].qty=#{v.inspect}",
              client.run(a, name: "create_order", items: [{ sku: sku, qty: v }],
                            delivery_slot_id: 1, delivery_date: ORDER_DAY, delivery_address: ADDRESS),
              supplied: { sku: sku, qty: v }
    end

    # Magnitude: a total past int4 (refused by the handler's sum check) and a qty past int4 (by the schema).
    price = catalog.first["price_cents"].to_i
    raise "redteam(getgrocery): catalogue row has no price_cents" unless price.positive?

    max_int4 = 2_147_483_647
    { "unpriceable cart"     => (max_int4 / price) + 1,
      "unstorable qty"       => max_int4 + 1 }.each do |why, v|
      refused "create_order items[0].qty=#{v} (#{why})",
              client.run(a, name: "create_order", items: [{ sku: sku, qty: v }],
                            delivery_slot_id: 1, delivery_date: ORDER_DAY, delivery_address: ADDRESS),
              supplied: { sku: sku, qty: v }
    end

    # A date is `YYYY-MM-DD` only; an ambiguous `09/01/2026` must not be guessed at.
    ["nope", "2026-13-45", "0000-01-01", "true",
     "[2026-09-01]", "20260101", "09/01/2026"].each do |v|
      refused "create_order delivery_date=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items, delivery_slot_id: 1,
                            delivery_address: ADDRESS, delivery_date: v),
              supplied: v
    end
    # The served zone is the demo's own guard; the schema says only `string`.
    ["", "   ", "1 Main St, Cork", "Dublin 99", "somewhere"].each do |v|
      refused "create_order delivery_address=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: 1, delivery_date: ORDER_DAY, delivery_address: v),
              supplied: v
    end

    control = client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: 1, delivery_date: ORDER_DAY, delivery_address: ADDRESS)
    unless control.status == 200
      @failures << "CONTROL well-formed create_order → HTTP #{control.status} " \
                   "#{control.body.inspect[0, 90]} (want 200; the probes above prove nothing " \
                   "on an origin that refuses everything)"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: @failures.empty?, skipped: false, status: 400,
      detail:  @failures.join(" | "),
    )
  end

  private

  # `supplied:` keeps the probe's own echoed bytes from reading as a leak.
  def refused(label, resp, supplied: nil)
    doc  = resp.body.is_a?(Hash) ? resp.body : {}
    scan = Kiosk::Redteam::LeakScan.scan(resp.body, LEAKS, supplied: supplied)
    return if resp.status == 400 && doc["code"] == "bad_request" && !scan.leak?

    @failures << "#{label} → HTTP #{resp.status} code=#{doc["code"].inspect}" \
                 "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
  end
end

# The paths a caller hunting for a multiplexed endpoint tries first; with or without a bearer.
class UnregisteredVerbIsOrdinaryRefusal < Kiosk::Redteam::Scenario
  UNREGISTERED = %w[query run].freeze

  def initialize
    super(
      name:        "UnregisteredVerbIsOrdinaryRefusal",
      category:    "surface",
      description: "POST /kiosk/query and POST /kiosk/run name no registered verb and no " \
                   "route — the ordinary 404 any undrawn path gets, bearer or not",
    )
  end

  def call(client, profile)
    a = client.register!

    results = UNREGISTERED.flat_map do |name|
      [[a.token, ""], [nil, " (anon)"]].map do |token, tag|
        uri     = URI("#{BASE_URL}/kiosk/#{name}")
        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{token}" if token
        req = Net::HTTP::Post.new(uri, headers)
        req.body = JSON.generate(name: "catalog")
        res  = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
        body = (JSON.parse(res.body) rescue {})
        [res.code.to_i == 404 && body["code"].nil?,
         "POST /kiosk/#{name}#{tag} → #{res.code}/#{body["code"].inspect} " \
         "(want 404 with no problem-document code)"]
      end
    end

    Kiosk::Redteam::Verdict.new(
      blocked: results.all? { |ok, _| ok },
      skipped: false,
      status:  404,
      detail:  results.all? { |ok, _| ok } ? "" :
                 "an unregistered verb name answers the wrong thing: " \
                 "#{results.reject { |ok, _| ok }.map(&:last).join(", ")}",
    )
  end
end

# The wrong method never reaches the action and carries no `Allow` header mapping the surface.
class MethodMismatch < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "MethodMismatch",
      category:    "surface",
      description: "A GET at an action's path draws no route: a plain 404, and the write " \
                   "never runs",
    )
  end

  def call(client, profile)
    a   = client.register!
    uri = URI("#{BASE_URL}/kiosk/create_order")
    res = Kiosk::TestHelpers::Wire.http_for(uri)
                   .request(Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{a.token}"))
    body    = (JSON.parse(res.body) rescue {})
    allow   = res["allow"]
    blocked = res.code.to_i == 404 && allow.nil? && body["code"].nil?

    Kiosk::Redteam::Verdict.new(
      blocked: blocked,
      skipped: false,
      status:  res.code.to_i,
      detail:  blocked ? "" :
                 "GET /kiosk/create_order → #{res.code}/#{body["code"].inspect} " \
                 "Allow=#{allow.inspect} (want a plain 404, no Allow, no code)",
    )
  end
end

# A past date must be a typed 400 naming the earliest bookable day, not an ambiguous `200 []` (§9.1).
class PastDeliveryDate < Kiosk::Redteam::Scenario
  ADDRESS = "1 Redteam St, Dublin 1"

  def initialize
    super(
      name:        "PastDeliveryDate",
      category:    "surface",
      description: "A delivery date before today is a typed 400 on BOTH delivery_slots and create_order — never 200 [], never an order",
    )
  end

  def call(client, profile)
    a = client.register!

    past   = (Date.today - 30).iso8601
    future = (Date.today + 7).iso8601

    bad = client.query(a, name: "delivery_slots", date: past, delivery_address: ADDRESS)
    ctl = client.query(a, name: "delivery_slots", date: future, delivery_address: ADDRESS)

    # The named day is in the operator's zone, not the runner's, so only its shape is asserted.
    detail  = bad.body.is_a?(Hash) ? bad.body["detail"].to_s : ""
    named   = detail.include?("in the past") && detail.match?(/\d{4}-\d{2}-\d{2}/)
    refused = bad.status == 400 && error_code(bad) == "bad_request" && named
    control = ctl.status == 200 && ctl.body.is_a?(Array) && ctl.body.any?

    sku      = (client.query(a, name: "catalog").body.then { |b| b.is_a?(Array) ? b : [] }).first&.dig("sku")
    order    = client.run(a, name: "create_order", items: [{ sku: sku, qty: 1 }],
                             delivery_slot_id: 1, delivery_address: ADDRESS, delivery_date: past)
    o_detail = order.body.is_a?(Hash) ? order.body["detail"].to_s : ""
    order_refused = order.status == 400 && error_code(order) == "bad_request" &&
                    o_detail.include?("in the past") && o_detail.match?(/\d{4}-\d{2}-\d{2}/)

    order_ctl = client.run(a, name: "create_order", items: [{ sku: sku, qty: 1 }],
                              delivery_slot_id: 1, delivery_address: ADDRESS, delivery_date: future)
    order_control = order_ctl.status == 200 && order_ctl.body.is_a?(Hash) &&
                    !order_ctl.body["order_id"].to_s.empty?

    ok = refused && control && order_refused && order_control
    Kiosk::Redteam::Verdict.new(
      blocked: ok,
      skipped: false,
      status:  bad.status,
      detail:  ok ? "" :
                 "delivery_slots date=#{past} → #{bad.status}/#{error_code(bad).inspect} " \
                 "detail=#{detail[0, 120].inspect}; " \
                 "CONTROL date=#{future} → #{ctl.status}/#{ctl.body.is_a?(Array) ? ctl.body.size : 0} rows; " \
                 "create_order delivery_date=#{past} → #{order.status}/#{error_code(order).inspect} " \
                 "detail=#{o_detail[0, 120].inspect}; " \
                 "CONTROL create_order delivery_date=#{future} → #{order_ctl.status} " \
                 "(want 400 bad_request naming the earliest bookable date on BOTH, and both controls answered)",
    )
  end
end

# Two fixed-offset zones 25 hours apart: their calendar dates differ at every instant.
CLOCK_EAST = "Pacific/Kiritimati" # UTC+14, no DST
CLOCK_WEST = "Pacific/Niue"       # UTC-11, no DST

# Read the day slightly ahead so it is still current when the last request lands.
CLOCK_PROBE_LEAD = 300

def clock_probe_day(offset_hours)
  (Time.now.utc + CLOCK_PROBE_LEAD + (offset_hours * 3600)).to_date.iso8601
end

# §3.8.5: the caller's zone is never inferred from locale or geolocation headers.
class CallerZoneIsNotInferred < Kiosk::Redteam::Scenario
  ADDRESS = "1 Redteam St, Dublin 1"

  BAIT_EAST = { "Accept-Language" => "gil-KI, gil;q=0.9",
                "X-Forwarded-For" => "202.6.96.1",
                "CF-IPCountry"    => "KI",
                "True-Client-IP"  => "202.6.96.1" }.freeze
  BAIT_WEST = { "Accept-Language" => "niu-NU, niu;q=0.9",
                "X-Forwarded-For" => "202.9.20.1",
                "CF-IPCountry"    => "NU",
                "True-Client-IP"  => "202.9.20.1" }.freeze

  def initialize
    super(
      name:        "CallerZoneIsNotInferred",
      category:    "surface",
      description: "With no Kiosk-Timezone the answer is the same whatever locale or geolocation hint the request also carries — while the header itself still moves it",
    )
  end

  UNREADABLE = "+03:00"

  def call(client, profile)
    a   = client.register!
    day = clock_probe_day(-11)

    ask = lambda do |headers|
      client.query(a, name: "delivery_slots", date: day, delivery_address: ADDRESS, headers: headers)
    end

    # Control: the declared header is read and moves the answer.
    declared = ask.call("Kiosk-Timezone" => CLOCK_WEST)
    ended    = ask.call("Kiosk-Timezone" => CLOCK_EAST)
    garbled  = ask.call("Kiosk-Timezone" => UNREADABLE)
    detail   = garbled.body.is_a?(Hash) ? garbled.body["detail"].to_s : ""
    gone     = ended.body.is_a?(Hash) ? ended.body["detail"].to_s : ""
    control  = declared.status == 200 && declared.body.is_a?(Array) && declared.body.any? &&
               ended.status == 400 && error_code(ended) == "bad_request" && gone.include?(day) &&
               garbled.status == 400 && error_code(garbled) == "bad_request" &&
               detail.include?("Kiosk-Timezone")

    bare       = ask.call({})
    baited_e   = ask.call(BAIT_EAST)
    baited_w   = ask.call(BAIT_WEST)
    same       = ->(r) { r.status == bare.status && r.body == bare.body }
    unmoved_e  = same.call(baited_e)
    unmoved_w  = same.call(baited_w)

    ok = control && unmoved_e && unmoved_w
    Kiosk::Redteam::Verdict.new(
      blocked: ok,
      skipped: false,
      status:  bare.status,
      detail:  ok ? "" :
                 "CONTROL date=#{day} declared #{CLOCK_WEST} → #{declared.status}/" \
                 "#{declared.body.is_a?(Array) ? declared.body.size : 0} rows, declared " \
                 "#{CLOCK_EAST} → #{ended.status}/#{error_code(ended).inspect} " \
                 "detail=#{gone[0, 80].inspect}, declared " \
                 "#{UNREADABLE} → #{garbled.status}/#{error_code(garbled).inspect} " \
                 "detail=#{detail[0, 80].inspect} (want 200 with rows on the clock that day " \
                 "belongs to, a 400 bad_request naming the day on the clock 25 hours ahead of " \
                 "it, and a 400 bad_request naming the header for an unreadable zone); " \
                 "bare → #{bare.status}, Kiribati-baited → " \
                 "#{baited_e.status} (same=#{unmoved_e}), Niue-baited → #{baited_w.status} " \
                 "(same=#{unmoved_w}) " \
                 "(want both baits byte-identical to bare — a declared clock, never an inferred one)",
    )
  end
end

# §3.8.9: one rendering per row, never a second wall clock in the caller's zone.
class OneRenderingPerRow < Kiosk::Redteam::Scenario
  ADDRESS   = "1 Redteam St, Dublin 1"
  RENDERING = %w[date slot_at label timezone].freeze

  def initialize
    super(
      name:        "OneRenderingPerRow",
      category:    "surface",
      description: "Two callers on clocks 25 hours apart get byte-identical windows, and neither answer names the caller's own zone",
    )
  end

  def call(client, profile)
    a = client.register!

    ask = lambda do |zone|
      client.query(a, name: "delivery_slots", delivery_address: ADDRESS,
                      headers: { "Kiosk-Timezone" => zone })
    end

    west = ask.call(CLOCK_WEST)
    east = ask.call(CLOCK_EAST)
    answered = [west, east].all? { |r| r.status == 200 && r.body.is_a?(Array) && r.body.any? }

    # Compared per shared slot: a window may begin between the two calls and drop out.
    rows_w = answered ? west.body.to_h { |r| [r["delivery_slot_id"], r] } : {}
    rows_e = answered ? east.body.to_h { |r| [r["delivery_slot_id"], r] } : {}
    shared = rows_w.keys & rows_e.keys
    agree  = shared.any? &&
             shared.all? { |id| RENDERING.all? { |f| rows_w[id][f] == rows_e[id][f] } }

    bytes    = [west, east].map { |r| JSON.generate(r.body) }
    no_caller_zone = bytes.none? { |b| b.include?(CLOCK_WEST) || b.include?(CLOCK_EAST) }

    renders = answered && (rows_w.values + rows_e.values).all? { |r|
      zone = r["timezone"].to_s
      !zone.empty? && zone != CLOCK_WEST && zone != CLOCK_EAST && r["label"].to_s.include?(zone)
    }

    ok = answered && agree && no_caller_zone && renders
    Kiosk::Redteam::Verdict.new(
      blocked: ok,
      skipped: false,
      status:  west.status,
      detail:  ok ? "" :
                 "delivery_slots on #{CLOCK_WEST} → #{west.status}/#{rows_w.size} rows, on " \
                 "#{CLOCK_EAST} → #{east.status}/#{rows_e.size} rows; #{shared.size} shared " \
                 "window(s) agree=#{agree}, caller's zone absent from both answers=" \
                 "#{no_caller_zone}, every row names its own rendering zone in its label=" \
                 "#{renders} (want one rendering per row, at the delivery address's clock)",
    )
  end
end

# §3.8.11: a machine timestamp (the auth challenge's exp) does not move with the caller's clock.
class MachineTimestampsIgnoreTheCallerClock < Kiosk::Redteam::Scenario
  TOLERANCE_SECONDS = 60

  def initialize
    super(
      name:        "MachineTimestampsIgnoreTheCallerClock",
      category:    "surface",
      description: "An auth challenge's exp is an instant, not a service time: it does not move with the caller's declared clock",
    )
  end

  def call(_client, _profile)
    wire = Kiosk::TestHelpers::Wire.new(base_url: BASE_URL)
    pem  = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
    path = "/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}"

    west_status, west_body = wire.get_json(path, {}, { "Kiosk-Timezone" => CLOCK_WEST })
    east_status, east_body = wire.get_json(path, {}, { "Kiosk-Timezone" => CLOCK_EAST })

    exp_w = west_body.is_a?(Hash) ? west_body["exp"] : nil
    exp_e = east_body.is_a?(Hash) ? east_body["exp"] : nil

    numeric  = exp_w.is_a?(Integer) && exp_e.is_a?(Integer)
    apart    = numeric ? (exp_w - exp_e).abs : nil
    answered = west_status == 200 && east_status == 200 && numeric &&
               exp_w > Time.now.utc.to_i && exp_e > Time.now.utc.to_i
    unmoved  = answered && apart <= TOLERANCE_SECONDS

    Kiosk::Redteam::Verdict.new(
      blocked: unmoved,
      skipped: false,
      status:  west_status,
      detail:  unmoved ? "" :
                 "auth/challenge on #{CLOCK_WEST} → #{west_status}/exp=#{exp_w.inspect}, on " \
                 "#{CLOCK_EAST} → #{east_status}/exp=#{exp_e.inspect}, apart by " \
                 "#{apart || "n/a"}s (want two live future instants " \
                 "within #{TOLERANCE_SECONDS}s — the two clocks are 90000s apart)",
    )
  end
end


scenarios = [
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::PrivilegeSelfSelection.new,
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  Kiosk::Redteam::Scenarios::WrongCurrencyCart.new,
  TamperedPriceCart.new,
  InflatedTotalCart.new,
  MalformedItemsCart.new,
  HostileArgShapes.new,
  UnregisteredVerbIsOrdinaryRefusal.new,
  MethodMismatch.new,
  PastDeliveryDate.new,
  CallerZoneIsNotInferred.new,
  OneRenderingPerRow.new,
  MachineTimestampsIgnoreTheCallerClock.new,
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new,
  # No KYC here — these must SKIP.
  Kiosk::Redteam::Scenarios::MissingKyc.new,
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,
  Kiosk::Redteam::Scenarios::ForgedKyc.new,
]

EXPECTED_SKIP_NAMES = %w[
  ExpiredKyc
  ForgedKyc
  MissingKyc
].freeze

puts "\n── getgrocery redteam battery ──"
puts "  base_url:       #{BASE_URL}"
puts "  pow_difficulty: #{profile.pow_difficulty} (register PoW #{profile.pow_difficulty.to_i > 0 ? "ON" : "OFF"})"
puts "  requires_kyc:   #{profile.requires_kyc}"
puts ""

runner  = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile:)
results = runner.run(scenarios)

# Exit 0 only when attacks ran and all were blocked; 2 when the skips differ from EXPECTED_SKIP_NAMES.
battery = Kiosk::Redteam::Battery.new
battery.absorb(results)
exit battery.report!(expected_skips: EXPECTED_SKIP_NAMES)
