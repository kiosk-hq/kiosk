# frozen_string_literal: true

# Red-team battery for getgrocery: attacks a running server and asserts every attack is refused.
# Usage, in kiosk-demo-getgrocery with its bundle:
#   SERVER_URL=http://127.0.0.1:3001 bundle exec ruby ../kiosk-redteam/suites/getgrocery.rb

require 'active_support/time'
require 'json'
require 'kiosk/redteam'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'uri'

DUBLIN = ActiveSupport::TimeZone['Europe/Dublin']

# The start of the window at `hour` on `day`, as a delivery_slots row publishes it.
def slot_at(day, hour = 8) = day.in_time_zone(DUBLIN).change(hour: hour).iso8601

# Every order here is booked tomorrow, so every window is open.
SLOT_AT   = slot_at(DUBLIN.today + 1)
SLOT_AT_2 = slot_at(DUBLIN.today + 1, 10)

BASE_URL = ENV.fetch('SERVER_URL')
ISSUER   = BASE_URL

REDTEAM_ADDRESS = '1 Redteam St, Dublin 1'

# Two fixed-offset zones 25 hours apart: their calendar dates differ at every instant.
CLOCK_EAST = 'Pacific/Kiritimati' # UTC+14, no DST
CLOCK_WEST = 'Pacific/Niue'       # UTC-11, no DST

# The catalog rows. A non-paginating query answers a BARE ARRAY, so there is no `rows` to unwrap.
def catalog_rows(client, customer)
  body = client.query(customer, name: 'catalog').body
  body.is_a?(Array) ? body : []
end

# The `detail` of a problem document, or '' when the body is not one.
def detail_text(resp) = resp.body.is_a?(Hash) ? resp.body['detail'].to_s : ''

# The number of rows in a list answer, or 0 when the body is not a list.
def row_count(resp) = resp.body.is_a?(Array) ? resp.body.size : 0

# The parsed JSON body, or {} when it does not parse.
def parsed_or_empty(text)
  JSON.parse(text)
rescue StandardError
  {}
end

# A verdict that computes its failure detail only when the attack was not blocked.
def scenario_verdict(blocked, status)
  Kiosk::Redteam::Verdict.new(blocked: blocked, skipped: false, status: status, detail: blocked ? '' : yield)
end

# The failure line for a probe that is not a clean typed 400, or nil when it is one.
# `supplied` keeps the probe's own echoed bytes from reading as a leak.
def refusal_failure(label, resp, leaks, supplied)
  code = resp.body.is_a?(Hash) ? resp.body['code'] : nil
  scan = Kiosk::Redteam::LeakScan.scan(resp.body, leaks, supplied: supplied)
  return if resp.status == 400 && code == 'bad_request' && !scan.leak?

  "#{label} → HTTP #{resp.status} code=#{code.inspect}#{" LEAKS #{scan.leak.inspect}" if scan.leak}#{scan.note}"
end

# The items are kept so pay_for can mirror the order at catalog prices (the cashier check).
def create_owned_order(client, customer)
  catalog = catalog_rows(client, customer)
  raise 'redteam: catalog returned empty' if catalog.empty?

  product = catalog.first
  order = place_owned_order(client, customer, product['sku'])
  { id: order['order_id'], total_cents: order['total_cents'].to_i,
    items: [{ sku: product['sku'], qty: 1, price_cents: product['price_cents'].to_i }] }
end

# The body of a placed one-item order for `sku`.
def place_owned_order(client, customer, sku)
  resp = client.run(customer, name: 'create_order', items: [{ sku: sku, qty: 1 }],
                              slot_at: SLOT_AT, delivery_address: REDTEAM_ADDRESS)
  raise "redteam: create_order failed (#{resp.status}): #{resp.body.inspect}" unless resp.status == 200
  raise 'redteam: create_order missing order_id' unless resp.body['order_id']

  resp.body
end

# An intent mandate capped 200 cents above the order, and a cart for the order at catalog prices.
def grocery_mandates(customer, owned_ref)
  now         = Time.now.to_i
  intent_id   = SecureRandom.uuid
  total_cents = owned_ref[:total_cents].to_i
  principal   = { user_id: customer.user_id, agent_id: customer.agent_id, iss: ISSUER }
  intent = { id: intent_id, **principal, scope: 'grocery', cap_amount_cents: total_cents + 200,
             currency: 'eur', exp: now + 600, iat: now }
  cart = { id: SecureRandom.uuid, intent_mandate_id: intent_id, **principal,
           line_items: [{ order_id: owned_ref[:id] }] + (owned_ref[:items] || []),
           total_amount_cents: total_cents, currency: 'eur', exp: now + 600, iat: now }
  { intent: intent, cart: cart }
end

profile = Kiosk::Redteam::Profile.new(
  # Register PoW is on; only "> 0" matters, the server's 402 challenges set the real difficulty.
  pow_difficulty: 1,
  requires_kyc: false,

  currency: 'eur',
  declared_roles: %w[customer],
  per_user_query: 'my_orders',

  result_id_key: 'order_id',
  row_id_key: 'order_id',

  create_owned: ->(client, customer) { create_owned_order(client, customer) },

  forge_action: 'create_order',
  forge_args: lambda { |client, _customer_a, customer_b|
    catalog = catalog_rows(client, customer_b)
    raise 'redteam: catalog empty for forge_args' if catalog.empty?

    { items: [{ sku: catalog.first['sku'], qty: 1 }], slot_at: SLOT_AT, delivery_address: REDTEAM_ADDRESS }
  },

  # One reschedule per order: the second attempt is the spent-resource beat.
  gated_action: 'reschedule_delivery',
  gated_args: ->(owned_ref) { { order_id: owned_ref[:id], slot_at: SLOT_AT_2 } },

  # On payment_setup_required the client calls payment_setup and pays again.
  pay_for: ->(_client, customer, owned_ref) { grocery_mandates(customer, owned_ref) },

  kyc_valid: nil,
  kyc_expired: nil,
  kyc_forged: nil
)

# getgrocery's own attacks, beside the shared ones in Kiosk::Redteam::Scenarios.
module GetgroceryScenarios
  # A below-catalog line price, with total and cap kept chain-consistent.
  class TamperedPriceCart < Kiosk::Redteam::Scenario
    def initialize
      super(name: 'TamperedPriceCart')
    end

    def call(client, profile)
      a = client.register!
      owned = profile.create_owned.call(client, a)
      m = profile.pay_for.call(client, a, owned)
      m[:cart] = m[:cart].merge(tampered_lines(owned))
      resp = client.pay(a, intent: m[:intent], cart: m[:cart])
      # 403 exactly: a 401 would mean the cashier never priced this cart.
      verdict_from(resp, expect: 403, detail: "below-catalog line price settled (HTTP #{resp.status})")
    end

    private

    # The first line 50 cents under the catalog price, and the total of the tampered lines.
    def tampered_lines(owned)
      items = (owned[:items] || []).map.with_index do |li, i|
        i.zero? ? li.merge(price_cents: li[:price_cents].to_i - 50) : li
      end
      { line_items: [{ order_id: owned[:id] }] + items,
        total_amount_cents: items.sum { |li| li[:qty].to_i * li[:price_cents].to_i } }
    end
  end

  # A cart whose total exceeds the sum of its lines must be rejected at capture.
  class InflatedTotalCart < Kiosk::Redteam::Scenario
    def initialize
      super(name: 'InflatedTotalCart')
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

  # A non-array (or non-object-element) `items` must be a typed 400, never a 500.
  class MalformedItemsCart < Kiosk::Redteam::Scenario
    ADDRESS = '1 Redteam St, Dublin 1'
    RUBY_INTERNALS = ['NoMethodError', 'TypeError', 'undefined method', 'no implicit conversion'].freeze

    BAD_ITEMS = [
      ['a String', 'sourdough-bread'],
      ['a Hash (one item, unwrapped)', { sku: 'sourdough-bread', qty: 1 }],
      ['an array of Strings',  ['sourdough-bread']],
      ['an array of Integers', [1, 2]],
      ['an Integer',           5],
      ['an array with null',   [nil]],
      ['an empty array',       []],
      ['absent',               nil]
    ].freeze

    def initialize
      super(name: 'MalformedItemsCart')
    end

    def call(client, _profile)
      a         = client.register!
      @failures = []
      @statuses = []
      BAD_ITEMS.each { |label, items| probe(client, a, label, items) }
      control(client, a)

      status = @statuses.find { |s| s != 400 && s != 200 } || 400
      Kiosk::Redteam::Verdict.new(blocked: @failures.empty?, skipped: false, status: status, detail: @failures.join(' | '))
    end

    private

    def probe(client, customer, label, items)
      args = { slot_at: SLOT_AT, delivery_address: ADDRESS }
      args[:items] = items unless items.nil?
      resp = client.run(customer, name: 'create_order', **args)
      @statuses << resp.status
      # The refusal may echo the probe's own bytes, so the scan is told what was sent.
      failure = refusal_failure("items #{label}", resp, RUBY_INTERNALS, args)
      @failures << failure if failure
    end

    # A well-formed cart still places an order.
    def control(client, customer)
      sku  = catalog_rows(client, customer).first['sku']
      resp = client.run(customer, name: 'create_order', items: [{ sku: sku, qty: 1 }],
                                  slot_at: SLOT_AT, delivery_address: ADDRESS)
      @statuses << resp.status
      return if resp.status == 200

      @failures << "CONTROL well-formed items → HTTP #{resp.status} #{resp.body.inspect} (want 200)"
    end
  end

  # Hostile shapes on create_order's scalar arguments, items[].qty, and reschedule_delivery's order_id.
  class HostileArgShapes < Kiosk::Redteam::Scenario
    ADDRESS = '2 Redteam Row, Dublin 2'

    LEAKS = ['NoMethodError', 'TypeError', 'undefined method', 'no implicit conversion',
             '::uuid', 'PG::', '22P02', 'invalid input syntax', 'ActiveRecord::'].freeze

    SHAPES = [true, false, [], {}, [1], { 'a' => 1 }, 'abc', 1.5].freeze

    # An instant is RFC 3339 with its offset; an ambiguous `09/01/2026 08:00` must not be guessed at.
    SLOT_TEXTS = ['nope', '2026-13-45T08:00:00Z', '0000-01-01T08:00:00Z', 'true', '2026-09-01',
                  '2026-09-01T08:00:00', '09/01/2026 08:00'].freeze

    # The served zone is the demo's own check; the schema says only `string`.
    ADDRESSES = ['', '   ', '1 Main St, Cork', 'Dublin 99', 'somewhere'].freeze

    def initialize
      super(name: 'HostileArgShapes')
    end

    def call(client, _profile)
      @client   = client
      @customer = client.register!
      @failures = []
      @sku      = first_sku
      probe_shapes
      probe_quantities
      probe_texts
      check_control
      Kiosk::Redteam::Verdict.new(blocked: @failures.empty?, skipped: false, status: 400, detail: @failures.join(' | '))
    end

    private

    def first_sku
      catalog = catalog_rows(@client, @customer)
      raise 'redteam(getgrocery): empty catalog' unless catalog.any?

      catalog.first['sku']
    end

    def create_order(items: [{ sku: @sku, qty: 1 }], slot_at: SLOT_AT, delivery_address: ADDRESS)
      @client.run(@customer, name: 'create_order', items: items, slot_at: slot_at, delivery_address: delivery_address)
    end

    def refuse_slot(value)
      refused "create_order slot_at=#{value.inspect}", create_order(slot_at: value), supplied: value
    end

    def probe_shapes
      SHAPES.each do |v|
        refuse_slot(v)
        refused "reschedule_delivery order_id=#{v.inspect}",
                @client.run(@customer, name: 'reschedule_delivery', order_id: v, slot_at: SLOT_AT),
                supplied: v
      end
      # Instants that start no window.
      [slot_at(DUBLIN.today + 1, 9), slot_at(DUBLIN.today + 1, 20), SLOT_AT.sub(':00:00', ':30:00')].each do |v|
        refuse_slot(v)
      end
    end

    # A qty no line carries (1000) and more lines than an order carries: the schema refuses both.
    def probe_quantities
      (SHAPES + [0, -1, 1000]).each do |v|
        refused "create_order items[0].qty=#{v.inspect}", create_order(items: [{ sku: @sku, qty: v }]),
                supplied: { sku: @sku, qty: v }
      end
      refused 'create_order with 1000 lines', create_order(items: [{ sku: @sku, qty: 1 }] * 1000)
    end

    def probe_texts
      SLOT_TEXTS.each { |v| refuse_slot(v) }
      ADDRESSES.each do |v|
        refused "create_order delivery_address=#{v.inspect}", create_order(delivery_address: v), supplied: v
      end
    end

    def check_control
      control = create_order
      return if control.status == 200

      @failures << "CONTROL well-formed create_order → HTTP #{control.status} " \
                   "#{control.body.inspect[0, 90]} (want 200; the probes above prove nothing " \
                   'on an origin that refuses everything)'
    end

    def refused(label, resp, supplied: nil)
      failure = refusal_failure(label, resp, LEAKS, supplied)
      @failures << failure if failure
    end
  end

  # The paths a caller hunting for a multiplexed endpoint tries first; with or without a bearer.
  class UnregisteredVerbIsOrdinaryRefusal < Kiosk::Redteam::Scenario
    UNREGISTERED = %w[query run].freeze

    def initialize
      super(name: 'UnregisteredVerbIsOrdinaryRefusal')
    end

    def call(client, _profile)
      a = client.register!
      results = UNREGISTERED.flat_map do |name|
        [[a.token, ''], [nil, ' (anon)']].map { |token, tag| post_unregistered(name, token, tag) }
      end
      misses = results.reject(&:first).map(&:last)
      scenario_verdict(misses.empty?, 404) do
        "an unregistered verb name answers the wrong thing: #{misses.join(', ')}"
      end
    end

    private

    # [refused as an ordinary 404, the line that describes the answer]
    def post_unregistered(name, token, tag)
      uri = URI("#{BASE_URL}/kiosk/#{name}")
      res = Kiosk::TestHelpers::Wire.http_for(uri).request(post_request(uri, token))
      body = parsed_or_empty(res.body)
      [res.code.to_i == 404 && body['code'].nil?,
       "POST /kiosk/#{name}#{tag} → #{res.code}/#{body['code'].inspect} " \
       '(want 404 with no problem-document code)']
    end

    def post_request(uri, token)
      headers = { 'Content-Type' => 'application/json' }
      headers['Authorization'] = "Bearer #{token}" if token
      req = Net::HTTP::Post.new(uri, headers)
      req.body = JSON.generate(name: 'catalog')
      req
    end
  end

  # The wrong method never reaches the action and carries no `Allow` header mapping the surface.
  class MethodMismatch < Kiosk::Redteam::Scenario
    def initialize
      super(name: 'MethodMismatch')
    end

    def call(client, _profile)
      res     = get_action(client.register!)
      body    = parsed_or_empty(res.body)
      allow   = res['allow']
      status  = res.code.to_i
      blocked = status == 404 && allow.nil? && body['code'].nil?
      scenario_verdict(blocked, status) do
        "GET /kiosk/create_order → #{res.code}/#{body['code'].inspect} " \
          "Allow=#{allow.inspect} (want a plain 404, no Allow, no code)"
      end
    end

    private

    def get_action(customer)
      uri = URI("#{BASE_URL}/kiosk/create_order")
      Kiosk::TestHelpers::Wire.http_for(uri)
                              .request(Net::HTTP::Get.new(uri, 'Authorization' => "Bearer #{customer.token}"))
    end
  end

  # A past date must be a typed 400 naming the earliest bookable day, not an ambiguous `200 []` (§9.1).
  class PastDeliveryDate < Kiosk::Redteam::Scenario
    ADDRESS = '1 Redteam St, Dublin 1'

    def initialize
      super(name: 'PastDeliveryDate')
    end

    def call(client, _profile)
      @client   = client
      @customer = client.register!
      ask_all
      ok = slots_refused? && slots_control? && order_refused? && order_control?
      scenario_verdict(ok, @bad.status) { "#{slots_detail}; #{orders_detail}" }
    end

    private

    def ask_all
      @past      = (Date.today - 30).iso8601
      @future    = (Date.today + 7).iso8601
      @bad       = slots_on(@past)
      @ctl       = slots_on(@future)
      sku        = catalog_rows(@client, @customer).first&.dig('sku')
      @order     = order_on(sku, @past)
      @order_ctl = order_on(sku, @future)
    end

    def slots_on(day)
      @client.query(@customer, name: 'delivery_slots', date: day, delivery_address: ADDRESS)
    end

    def order_on(sku, day)
      @client.run(@customer, name: 'create_order', items: [{ sku: sku, qty: 1 }],
                             slot_at: slot_at(Date.iso8601(day)), delivery_address: ADDRESS)
    end

    # The named day is in the operator's zone, not the runner's, so only its shape is asserted.
    def slots_refused?
      detail = detail_text(@bad)
      @bad.status == 400 && error_code(@bad) == 'bad_request' &&
        detail.include?('in the past') && detail.match?(/\d{4}-\d{2}-\d{2}/)
    end

    def slots_control? = @ctl.status == 200 && @ctl.body.is_a?(Array) && @ctl.body.any?

    def order_refused?
      detail = detail_text(@order)
      @order.status == 400 && error_code(@order) == 'bad_request' &&
        detail.include?('no longer bookable') && detail.include?(@past)
    end

    def order_control?
      @order_ctl.status == 200 && @order_ctl.body.is_a?(Hash) && !@order_ctl.body['order_id'].to_s.empty?
    end

    def slots_detail
      "delivery_slots date=#{@past} → #{@bad.status}/#{error_code(@bad).inspect} " \
        "detail=#{detail_text(@bad)[0, 120].inspect}; " \
        "CONTROL date=#{@future} → #{@ctl.status}/#{row_count(@ctl)} rows"
    end

    def orders_detail
      "create_order slot_at on #{@past} → #{@order.status}/#{error_code(@order).inspect} " \
        "detail=#{detail_text(@order)[0, 120].inspect}; " \
        "CONTROL create_order slot_at on #{@future} → #{@order_ctl.status} " \
        '(want 400 bad_request naming the day on BOTH, and both controls answered)'
    end
  end

  # §3.8.5: a declared zone never moves a service day, and no zone is inferred from locale or geolocation headers.
  class CallerZoneIsNotInferred < Kiosk::Redteam::Scenario
    ADDRESS = '1 Redteam St, Dublin 1'

    BAIT_EAST = { 'Accept-Language' => 'gil-KI, gil;q=0.9',
                  'X-Forwarded-For' => '202.6.96.1',
                  'CF-IPCountry' => 'KI',
                  'True-Client-IP' => '202.6.96.1' }.freeze
    BAIT_WEST = { 'Accept-Language' => 'niu-NU, niu;q=0.9',
                  'X-Forwarded-For' => '202.9.20.1',
                  'CF-IPCountry' => 'NU',
                  'True-Client-IP' => '202.9.20.1' }.freeze

    def initialize
      super(name: 'CallerZoneIsNotInferred')
    end

    UNREADABLE = '+03:00'

    def call(client, _profile)
      @client   = client
      @customer = client.register!
      @day      = (Date.today + 1).iso8601
      ask_all
      ok = control? && [@west, @east, @baited_e, @baited_w].all? { unmoved?(it) }
      scenario_verdict(ok, @bare.status) { "#{control_detail}; #{moved_detail}" }
    end

    private

    def ask(headers)
      @client.query(@customer, name: 'delivery_slots', date: @day, delivery_address: ADDRESS, headers: headers)
    end

    def ask_all
      @bare     = ask({})
      @garbled  = ask('Kiosk-Timezone' => UNREADABLE)
      @west     = ask('Kiosk-Timezone' => CLOCK_WEST)
      @east     = ask('Kiosk-Timezone' => CLOCK_EAST)
      @baited_e = ask(BAIT_EAST)
      @baited_w = ask(BAIT_WEST)
    end

    # The origin reads the header: an unreadable zone is refused by name.
    def control?
      @bare.status == 200 && @bare.body.is_a?(Array) && @bare.body.any? &&
        @garbled.status == 400 && error_code(@garbled) == 'bad_request' &&
        detail_text(@garbled).include?('Kiosk-Timezone')
    end

    def unmoved?(resp) = resp.status == @bare.status && resp.body == @bare.body

    def control_detail
      "CONTROL date=#{@day} bare → #{@bare.status}/#{row_count(@bare)} rows, declared #{UNREADABLE} → " \
        "#{@garbled.status}/#{error_code(@garbled).inspect} detail=#{detail_text(@garbled)[0, 80].inspect} " \
        '(want 200 with rows, and a 400 bad_request naming the header)'
    end

    def moved_detail
      "declared #{CLOCK_WEST} same=#{unmoved?(@west)}, declared #{CLOCK_EAST} same=#{unmoved?(@east)}, " \
        "Kiribati-baited same=#{unmoved?(@baited_e)}, Niue-baited same=#{unmoved?(@baited_w)} " \
        "(want all four byte-identical to bare — a service day is on the address's clock)"
    end
  end

  # §3.8.9: one rendering per row, never a second wall clock in the caller's zone.
  class OneRenderingPerRow < Kiosk::Redteam::Scenario
    ADDRESS   = '1 Redteam St, Dublin 1'
    RENDERING = %w[slot_at label timezone].freeze

    def initialize
      super(name: 'OneRenderingPerRow')
    end

    def call(client, _profile)
      a = client.register!
      @west = ask(client, a, CLOCK_WEST)
      @east = ask(client, a, CLOCK_EAST)
      index_rows
      ok = @answered && agree? && no_caller_zone? && renders?
      scenario_verdict(ok, @west.status) { failure_detail }
    end

    private

    def ask(client, customer, zone)
      client.query(customer, name: 'delivery_slots', delivery_address: ADDRESS,
                             headers: { 'Kiosk-Timezone' => zone })
    end

    # Compared per shared slot: a window may begin between the two calls and drop out.
    def index_rows
      @answered = [@west, @east].all? { |r| r.status == 200 && r.body.is_a?(Array) && r.body.any? }
      @rows_w   = rows_by_slot(@west)
      @rows_e   = rows_by_slot(@east)
    end

    def rows_by_slot(resp) = @answered ? resp.body.to_h { |r| [r['slot_at'], r] } : {}

    def shared_slots = @rows_w.keys & @rows_e.keys

    def agree?
      shared = shared_slots
      shared.any? && shared.all? { |id| RENDERING.all? { |f| @rows_w[id][f] == @rows_e[id][f] } }
    end

    def no_caller_zone?
      bytes = [@west, @east].map { |r| JSON.generate(r.body) }
      bytes.none? { |b| b.include?(CLOCK_WEST) || b.include?(CLOCK_EAST) }
    end

    def renders?
      return false unless @answered

      (@rows_w.values + @rows_e.values).all? do |r|
        zone = r['timezone'].to_s
        !zone.empty? && zone != CLOCK_WEST && zone != CLOCK_EAST && r['label'].to_s.include?(zone)
      end
    end

    def failure_detail
      "delivery_slots on #{CLOCK_WEST} → #{@west.status}/#{@rows_w.size} rows, on " \
        "#{CLOCK_EAST} → #{@east.status}/#{@rows_e.size} rows; #{shared_slots.size} shared " \
        "window(s) agree=#{agree?}, caller's zone absent from both answers=" \
        "#{no_caller_zone?}, every row names its own rendering zone in its label=" \
        "#{renders?} (want one rendering per row, at the delivery address's clock)"
    end
  end

  # §3.8.11: a machine timestamp (the auth challenge's exp) does not move with the caller's clock.
  class MachineTimestampsIgnoreTheCallerClock < Kiosk::Redteam::Scenario
    TOLERANCE_SECONDS = 60

    def initialize
      super(name: 'MachineTimestampsIgnoreTheCallerClock')
    end

    def call(_client, _profile)
      ask_challenges
      unmoved = answered? && apart <= TOLERANCE_SECONDS
      scenario_verdict(unmoved, @west_status) do
        "auth/challenge on #{CLOCK_WEST} → #{@west_status}/exp=#{@exp_w.inspect}, on " \
          "#{CLOCK_EAST} → #{@east_status}/exp=#{@exp_e.inspect}, apart by " \
          "#{apart || 'n/a'}s (want two live future instants " \
          "within #{TOLERANCE_SECONDS}s — the two clocks are 90000s apart)"
      end
    end

    private

    def ask_challenges
      wire = Kiosk::TestHelpers::Wire.new(base_url: BASE_URL)
      pem  = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
      path = "/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}"
      @west_status, west_body = wire.get_json(path, {}, { 'Kiosk-Timezone' => CLOCK_WEST })
      @east_status, east_body = wire.get_json(path, {}, { 'Kiosk-Timezone' => CLOCK_EAST })
      @exp_w = west_body.is_a?(Hash) ? west_body['exp'] : nil
      @exp_e = east_body.is_a?(Hash) ? east_body['exp'] : nil
    end

    def numeric? = @exp_w.is_a?(Integer) && @exp_e.is_a?(Integer)

    def apart = numeric? ? (@exp_w - @exp_e).abs : nil

    def answered?
      now = Time.now.utc.to_i
      @west_status == 200 && @east_status == 200 && numeric? && @exp_w > now && @exp_e > now
    end
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
  GetgroceryScenarios::TamperedPriceCart.new,
  GetgroceryScenarios::InflatedTotalCart.new,
  GetgroceryScenarios::MalformedItemsCart.new,
  GetgroceryScenarios::HostileArgShapes.new,
  GetgroceryScenarios::UnregisteredVerbIsOrdinaryRefusal.new,
  GetgroceryScenarios::MethodMismatch.new,
  GetgroceryScenarios::PastDeliveryDate.new,
  GetgroceryScenarios::CallerZoneIsNotInferred.new,
  GetgroceryScenarios::OneRenderingPerRow.new,
  GetgroceryScenarios::MachineTimestampsIgnoreTheCallerClock.new,
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new,
  # No KYC here — these must SKIP.
  Kiosk::Redteam::Scenarios::MissingKyc.new,
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,
  Kiosk::Redteam::Scenarios::ForgedKyc.new
]

EXPECTED_SKIP_NAMES = %w[
  ExpiredKyc
  ForgedKyc
  MissingKyc
].freeze

puts "\n── getgrocery redteam battery ──"
puts "  base_url:       #{BASE_URL}"
puts "  pow_difficulty: #{profile.pow_difficulty} (register PoW #{profile.pow_difficulty.to_i.positive? ? 'ON' : 'OFF'})"
puts "  requires_kyc:   #{profile.requires_kyc}"
puts ''

runner  = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile:)
results = runner.run(scenarios)

# Exit 0 only when attacks ran and all were blocked; 2 when the skips differ from EXPECTED_SKIP_NAMES.
battery = Kiosk::Redteam::Battery.new
battery.absorb(results)
exit battery.report!(expected_skips: EXPECTED_SKIP_NAMES)
