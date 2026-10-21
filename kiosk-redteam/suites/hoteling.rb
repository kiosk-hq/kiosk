# frozen_string_literal: true

# Red-team battery for hoteling: attacks a running server and asserts every attack is refused.
# Usage, in kiosk-demo-hoteling with its bundle:
#   SERVER_URL=http://127.0.0.1:3003 bundle exec ruby ../kiosk-redteam/suites/hoteling.rb

require 'kiosk/redteam'
require 'jwt'
require 'net/http'
require 'securerandom'
require 'uri'
require 'date'

BASE_URL = ENV.fetch('SERVER_URL')

# Clear of today's inventory; every run starts from db:reset.
CHECK_IN  = (Date.today + 30).to_s.freeze
CHECK_OUT = (Date.today + 33).to_s.freeze
NIGHTS    = 3

# First property with a room free for CHECK_IN..CHECK_OUT; earlier beats may exhaust one.
FIND_AVAILABLE = lambda { |client, principal|
  props_resp = client.query(principal, name: 'properties')
  all_props  = props_resp.body.is_a?(Array) ? props_resp.body : []
  raise 'redteam(hoteling): no properties in catalog' if all_props.empty?

  all_props.each do |p|
    avail_resp = client.query(principal, name: 'availability',
                                         property_id: p['property_id'], check_in: CHECK_IN, check_out: CHECK_OUT)
    avail_rows = avail_resp.body.is_a?(Array) ? avail_resp.body : []
    next if avail_rows.empty?

    return { prop: p, room: avail_rows.first }
  end

  raise "redteam(hoteling): no room available at any property for #{CHECK_IN}..#{CHECK_OUT} " \
        "(#{all_props.size} properties checked)"
}

profile = Kiosk::Redteam::Profile.new(
  # Register PoW is on, so RegistrationWithoutPow runs; only > 0 matters.
  pow_difficulty: 1,
  requires_kyc: false, # no KYC gate

  # declared_roles mirrors config/initializers/kiosk.rb: DeviceGrantRoleSelfSelection must name a real role.
  # WrongCurrencyPayment probes with a currency other than this one.
  currency: 'eur',
  declared_roles: %w[customer],

  per_user_query: 'my_bookings',

  row_id_key: 'booking_id',
  result_id_key: 'booking_id',

  create_owned: lambda { |client, principal|
    room = FIND_AVAILABLE.call(client, principal)[:room]

    rsv_resp = client.run(principal, name: 'reserve_room',
                                     room_type_id: room['room_type_id'],
                                     check_in: CHECK_IN,
                                     check_out: CHECK_OUT)
    raise "redteam(hoteling): reserve_room failed (#{rsv_resp.status}): #{rsv_resp.body.inspect}" \
      unless rsv_resp.status == 200

    booking_id    = rsv_resp.body['booking_id']
    total_cents   = rsv_resp.body['total_cents'].to_i
    nightly_price = rsv_resp.body['nightly_price_cents'].to_i

    {
      id: booking_id,
      code: room['name'],
      total_cents: total_cents,
      nights: NIGHTS,
      nightly_price: nightly_price,
      checkout_jwt: rsv_resp.body['checkout_jwt']
    }
  },

  # The scenario injects user_id; reserve_room's schema forbids extra properties, so it is a 400.
  forge_action: 'reserve_room',
  forge_args: lambda { |client, principal_a, _principal_b|
    room = FIND_AVAILABLE.call(client, principal_a)[:room]

    {
      room_type_id: room['room_type_id'],
      check_in: CHECK_IN,
      check_out: CHECK_OUT
    }
  },

  # The checkout reserve_room returns: a line naming the booking, then the nights.
  pay_for: ->(_client, _principal, owned_ref) { owned_ref[:checkout_jwt] },

  # No KYC — hoteling does not require identity verification
  kyc_valid: nil,
  kyc_expired: nil,
  kyc_forged: nil
)

# hoteling's own attacks, beside the shared ones in Kiosk::Redteam::Scenarios.
module HotelingScenarios
  # The operator signs what lands on the counter: a checkout changed after it signed it is refused.

  # A checkout whose total is below the operator's quoted booking price must be refused before capture.
  class TamperedPriceCheckout < Kiosk::Redteam::Scenario
    def initialize
      super(name: 'TamperedPriceCheckout')
    end

    def call(client, profile)
      a = client.register!
      owned = profile.create_owned.call(client, a)
      resp = client.pay(a, lowered(profile.pay_for.call(client, a, owned), owned))
      # 403 by name: a 401 would mean the checkout was never verified.
      verdict_from(resp, expect: 403, expect_code: %w[forbidden], detail: "below-quote checkout settled (HTTP #{resp.status})")
    end

    private

    # Lower the line price too, so the lines still sum to the total.
    def lowered(checkout_jwt, owned)
      nights        = owned[:nights].to_i.nonzero? || NIGHTS
      lowered_total = owned[:total_cents].to_i - 100
      tampered_checkout(checkout_jwt, line_items: [{ booking_id: owned[:id] }, { qty: nights, price_cents: (lowered_total / nights) }],
                                      total_amount_cents: lowered_total)
    end
  end

  # A checkout whose total exceeds the sum of its line items must be refused before capture.
  class InflatedTotalCheckout < Kiosk::Redteam::Scenario
    def initialize
      super(name: 'InflatedTotalCheckout')
    end

    def call(client, profile)
      a = client.register!
      owned = profile.create_owned.call(client, a)
      forged = tampered_checkout(profile.pay_for.call(client, a, owned), total_amount_cents: owned[:total_cents].to_i + 50)
      resp = client.pay(a, forged)
      # 403 by name — see TamperedPriceCheckout above.
      verdict_from(resp, expect: 403, expect_code: %w[forbidden], detail: "total above the line-item sum settled (HTTP #{resp.status})")
    end
  end

  # A checkout naming a junk booking_id, signed by a key the hotel never held, is a 403 that leaks no SQL.
  class ForgedCheckoutRef < Kiosk::Redteam::Scenario
    MALFORMED     = ['not-a-uuid', '1; DROP TABLE bookings', '', '00000000-0000-4000-8000-000000000000'].freeze
    SQL_INTERNALS = ['::uuid', 'PG::', '22P02', 'invalid input syntax'].freeze

    def initialize
      super(name: 'ForgedCheckoutRef')
    end

    def call(client, _profile)
      principal    = client.register!
      @failures    = []
      @unevaluated = []
      @statuses    = []
      MALFORMED.each { |junk| check("pay checkout booking_id=#{junk.inspect}", client.pay(principal, forged(principal, junk)), supplied: junk) }
      probes_verdict(@statuses.find { |s| s != 403 } || 403, @failures, @unevaluated)
    end

    private

    # Reserves nothing: the signature check runs before the cashier looks the booking up.
    def forged(principal, junk)
      claims = { iss: BASE_URL, sub: principal.user_id, iat: Time.now.to_i, merchant: { id: BASE_URL, name: 'hoteling' },
                 currency: 'eur', total_amount_cents: 100, line_items: [{ booking_id: junk }, { qty: 1, price_cents: 100 }] }
      JWT.encode(claims, OpenSSL::PKey::RSA.generate(2048), 'PS256')
    end

    # `supplied:` discounts the probe's own echoed bytes from the leak scan.
    def check(label, resp, supplied: nil)
      @statuses << resp.status
      answer = "#{label} → HTTP #{resp.status} code=#{error_code(resp).inspect}"
      return @unevaluated << answer if Kiosk::Redteam.unevaluated?(resp)

      scan = Kiosk::Redteam::LeakScan.scan(resp.body, SQL_INTERNALS, supplied: supplied)
      return if resp.status == 403 && error_code(resp) == 'forbidden' && !scan.leak?

      @failures << "#{answer}#{leaks(scan)}"
    end

    def leaks(scan) = "#{" LEAKS #{scan.leak.inspect}" if scan.leak}#{scan.note}"
  end

  # Probes: same nights (B), overlapping nights (A), abutting nights (control), dated hotel_detail.
  class DoubleBookedRoom < Kiosk::Redteam::Scenario
    DBL_IN       = (Date.today + 60).to_s.freeze
    DBL_OUT      = (Date.today + 63).to_s.freeze
    DBL_IN_OVL   = (Date.today + 61).to_s.freeze   # overlaps DBL_IN..DBL_OUT
    DBL_OUT_OVL  = (Date.today + 64).to_s.freeze
    DBL_OUT_ADJ  = (Date.today + 66).to_s.freeze   # DBL_OUT..DBL_OUT_ADJ abuts, no overlap

    def initialize
      super(name: 'DoubleBookedRoom')
    end

    def call(client, _profile)
      a = client.register!
      b = client.register!
      @failures = []
      @statuses = []
      found = free_room(client, a)
      return no_room_verdict if found.nil?

      probe_reservations(client, a, b, found[:room_type_id])
      probe_hotel_detail(client, a, found[:property_id], found[:room_type_id])
      verdict
    end

    private

    def verdict
      Kiosk::Redteam::Verdict.new(blocked: @failures.empty?, skipped: false,
                                  status: @statuses.find { |s| s == 409 } || @statuses.last.to_i,
                                  detail: @failures.join(' | '))
    end

    def no_room_verdict
      Kiosk::Redteam::Verdict.new(
        blocked: false, skipped: false, status: 0,
        detail: "no room available at any property for #{DBL_IN}..#{DBL_OUT} — cannot test the overlap guard"
      )
    end

    def probe_reservations(client, owner, rival, rid)
      held = reserve(client, owner, rid, DBL_IN, DBL_OUT)
      @statuses << held.status
      @failures << "setup: A's first reserve_room → HTTP #{held.status} #{held.body.inspect}" unless held.status == 200

      # 1 — the headline: another customer takes the identical room-night.
      conflict('B reserve_room same nights', reserve(client, rival, rid, DBL_IN, DBL_OUT))

      # 2 — overlap, not equality: one night in common is one night too many.
      conflict('A reserve_room overlapping nights', reserve(client, owner, rid, DBL_IN_OVL, DBL_OUT_OVL))

      abutting(client, rival, rid)
    end

    # 3 — CONTROL: checkout day is the next guest's check-in day, so this must succeed.
    def abutting(client, principal, rid)
      adjacent = reserve(client, principal, rid, DBL_OUT, DBL_OUT_ADJ)
      @statuses << adjacent.status
      return if adjacent.status == 200

      @failures << "CONTROL abutting nights #{DBL_OUT}..#{DBL_OUT_ADJ} → HTTP #{adjacent.status} " \
                   "(want 200; a checkout day is the next guest's check-in day)"
    end

    # 4 — dated hotel_detail must not offer the taken room; undated lists every room type.
    def probe_hotel_detail(client, principal, pid, rid)
      dated = client.query(principal, name: 'hotel_detail', property_id: pid,
                                      check_in: DBL_IN, check_out: DBL_OUT)
      @statuses << dated.status
      @failures << "hotel_detail(#{DBL_IN}..#{DBL_OUT}) still offers the taken room_type #{rid}" if room_ids(dated).include?(rid)
      undated_lists_every_room(client.query(principal, name: 'hotel_detail', property_id: pid), rid)
    end

    def undated_lists_every_room(undated, rid)
      listed   = room_ids(undated).include?(rid)
      row      = detail(undated)
      return if listed && row.key?('check_in') && row['check_in'].nil?

      @failures << 'undated hotel_detail must list every room type, with a null check_in ' \
                   "(room #{rid} listed: #{listed}, check_in: #{row['check_in'].inspect})"
    end

    def reserve(client, principal, room_type_id, check_in, check_out)
      client.run(principal, name: 'reserve_room', room_type_id:, check_in:, check_out:)
    end

    # Exactly 409 conflict: a 500 also creates no row.
    def conflict(label, resp)
      @statuses << resp.status
      return if resp.status == 409 && error_code(resp) == 'conflict'

      @failures << "#{label} → HTTP #{resp.status} code=#{error_code(resp).inspect} (want 409 conflict)"
    end

    def free_room(client, principal)
      rows = Array(client.query(principal, name: 'properties').body)
      rows.each do |p|
        avail = client.query(principal, name: 'availability', property_id: p['property_id'],
                                        check_in: DBL_IN, check_out: DBL_OUT)
        first = Array(avail.body).first
        next if first.nil?

        return { property_id: p['property_id'], room_type_id: first['room_type_id'] }
      end
      nil
    end

    # hotel_detail answers a one-row array; empty means no such property.
    def detail(resp)
      Array(resp.body).first || {}
    end

    def room_ids(resp)
      Array(detail(resp)['room_types']).map { |r| r['room_type_id'] }
    end
  end

  # Raw requests the redteam Client will not build: unregistered paths and wrong methods.
  module RawWire
    # A nil principal sends no token.
    def raw(principal, method, path, body = nil)
      uri     = URI("#{BASE_URL}#{path}")
      headers = { 'Content-Type' => 'application/json' }
      headers.merge!(Kiosk::TestHelpers::Dpop.headers(principal.token, principal.rsa_key, method: method.to_s.upcase, url: uri.to_s)) if principal
      req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri, headers)
      req.body = JSON.generate(body) if body
      res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
      [res, parsed(res.body)]
    end

    # The JSON body, or {} when the body is not JSON.
    def parsed(body)
      JSON.parse(body)
    rescue StandardError
      {}
    end
  end

  # Sends one verb call and records it unless it is a clean typed 400.
  module ShapeRefusals
    # Database vocabulary no error body may carry.
    LEAKS = ['::uuid', '::integer', '::date', 'PG::', '22P02', 'invalid input syntax',
             'ActiveRecord::', 'ActiveModel::', 'RangeError'].freeze

    private

    def reserve(label, supplied, **args)
      refused(label, @client.run(@principal, name: 'reserve_room', **args), supplied:)
    end

    def availability(label, supplied, **args)
      refused(label, @client.query(@principal, name: 'availability', **args), supplied:)
    end

    def search(label, supplied, **args)
      refused(label, @client.query(@principal, name: 'search_hotels', **args), supplied:)
    end

    def refused(label, resp, supplied: nil)
      note(label, resp.status, resp.body.is_a?(Hash) ? resp.body : {}, supplied: supplied)
    end

    # `supplied:` discounts the probe's own echoed bytes from the leak scan.
    def note(label, status, doc, supplied: nil)
      scan = Kiosk::Redteam::LeakScan.scan(doc, LEAKS, supplied: supplied)
      return if status == 400 && doc['code'] == 'bad_request' && !scan.leak?

      @failures << "#{label} → HTTP #{status} code=#{doc['code'].inspect}" \
                   "#{" LEAKS #{scan.leak.inspect}" if scan.leak}#{scan.note}"
    end
  end

  # Unknown property_id and an unpriceable stay reach hoteling's own guards; the schema refuses the rest.
  class HostileArgShapes < Kiosk::Redteam::Scenario
    include RawWire
    include ShapeRefusals

    # Clear of the shared inventory and DoubleBookedRoom's window; nothing here books.
    PROBE_IN  = (Date.today + 80).to_s.freeze
    PROBE_OUT = (Date.today + 83).to_s.freeze

    INT_SHAPES  = [true, false, [], {}, [1], { 'a' => 1 }, 'abc', nil, 1.5, '0x10'].freeze
    DATE_SHAPES = [true, [], {}, nil, 20_260_901, 'nope', '', '2026-02-30', '09/01/2026',
                   "2026-09-01'; --", ['2026-09-01']].freeze

    BEYOND_INT4 = 2_147_483_648 # one past PostgreSQL `integer`

    def initialize
      super(name: 'HostileArgShapes')
    end

    def call(client, _profile)
      @client    = client
      @principal = client.register!
      @failures  = []
      prop, room = live_pair
      probe_reserve_room(room)
      probe_availability(prop)
      probe_search_hotels
      probe_own_guards(room)
      control_availability(prop)
      Kiosk::Redteam::Verdict.new(blocked: @failures.empty?, skipped: false, status: 400, detail: @failures.join(' | '))
    end

    private

    # Action path: real JSON types.
    def probe_reserve_room(room)
      INT_SHAPES.each { |v| reserve "reserve_room room_type_id=#{v.inspect}", v, room_type_id: v, check_in: PROBE_IN, check_out: PROBE_OUT }
      DATE_SHAPES.each do |v|
        reserve "reserve_room check_in=#{v.inspect}", v, room_type_id: room, check_in: v, check_out: PROBE_OUT
        reserve "reserve_room check_out=#{v.inspect}", v, room_type_id: room, check_in: PROBE_IN, check_out: v
      end
    end

    # Query path: junk strings, then the two bracket spellings that decode to an Array and a Hash.
    def probe_availability(prop)
      %w[abc true 0x10].each { |v| availability "availability property_id=#{v.inspect}", v, property_id: v, check_in: PROBE_IN, check_out: PROBE_OUT }
      ['nope', '', "2026-09-01'; --"].each do |v|
        availability "availability check_in=#{v.inspect}", v, property_id: prop, check_in: v, check_out: PROBE_OUT
      end
      ['nope', '', '2026-02-30', '09/01/2026'].each do |v|
        availability "availability check_out=#{v.inspect}", v, property_id: prop, check_in: PROBE_IN, check_out: v
      end
      probe_bracket_dates(prop)
    end

    def probe_bracket_dates(prop)
      ['check_in%5B%5D', 'check_in%5Bx%5D'].each do |bracket|
        res, doc = raw(@principal, :get,
                       "/kiosk/availability?property_id=#{prop}&check_out=#{PROBE_OUT}&#{bracket}=#{PROBE_IN}")
        note "availability #{bracket}", res.code.to_i, doc, supplied: [bracket, PROBE_IN]
      end
    end

    # search_hotels filters: integer ranges and enums; a silent miss would answer 200 [].
    def probe_search_hotels
      %W[abc true 0 9 1.5 0x10 #{BEYOND_INT4}].each { |v| search "search_hotels min_stars=#{v.inspect}", v, min_stars: v }
      %W[abc true -1 1.5 #{BEYOND_INT4}].each { |v| search "search_hotels max_price_cents=#{v.inspect}", v, max_price_cents: v }
      ['nope', '', "Sultanahmet'; --"].each do |v|
        search "search_hotels neighbourhood=#{v.inspect}", v, neighbourhood: v
        search "search_hotels amenity=#{v.inspect}", v, amenity: v
      end
      control_search
    end

    # CONTROL: well-formed filters still answer 200 with an array.
    def control_search
      filtered = @client.query(@principal, name: 'search_hotels', min_stars: 1, max_price_cents: 50_000)
      return if filtered.status == 200 && filtered.body.is_a?(Array)

      @failures << "CONTROL well-formed search_hotels filters → HTTP #{filtered.status} " \
                   "#{filtered.body.inspect[0, 80]} (want 200 + an array)"
    end

    # The two that reach hoteling's own guards.
    def probe_own_guards(room)
      unknown_property
      # Asked from the far end: an old check_in would hit the past-date refusal first.
      reserve 'reserve_room check_out="9999-12-31" (unpriceable stay)', '9999-12-31',
              room_type_id: room, check_in: PROBE_IN, check_out: '9999-12-31'
    end

    def unknown_property
      unknown = @client.query(@principal, name: 'availability', property_id: 999_999,
                                          check_in: PROBE_IN, check_out: PROBE_OUT)
      return if unknown.status == 404 && error_code(unknown) == 'not_found'

      @failures << "unknown property_id → HTTP #{unknown.status} " \
                   "code=#{error_code(unknown).inspect} (want 404/not_found; a 200 [] would " \
                   'assert the hotel exists and merely has no rooms)'
    end

    # CONTROL: a well-formed call answers 200, so the refusals are not vacuous.
    def control_availability(prop)
      control = @client.query(@principal, name: 'availability', property_id: prop,
                                          check_in: PROBE_IN, check_out: PROBE_OUT)
      return if control.status == 200 && control.body.is_a?(Array)

      @failures << "CONTROL well-formed availability → HTTP #{control.status} " \
                   "#{control.body.inspect[0, 80]} (want 200 + an array; the shape probes above " \
                   'prove nothing on an origin that refuses everything)'
    end

    # A real property/room pair, so only the shape under test is wrong.
    def live_pair
      props = @client.query(@principal, name: 'properties').body
      raise 'redteam(hoteling): no properties' unless props.is_a?(Array) && props.any?

      props.each do |p|
        rows = @client.query(@principal, name: 'availability', property_id: p['property_id'],
                                         check_in: PROBE_IN, check_out: PROBE_OUT).body
        return [p['property_id'], rows.first['room_type_id']] if rows.is_a?(Array) && rows.any?
      end
      raise "redteam(hoteling): no availability for #{PROBE_IN}..#{PROBE_OUT}"
    end
  end

  # The two names a caller hunting for a multiplexed endpoint tries first.
  class UnregisteredVerbIsOrdinaryRefusal < Kiosk::Redteam::Scenario
    include RawWire

    def initialize
      super(name: 'UnregisteredVerbIsOrdinaryRefusal')
    end

    def call(client, _profile)
      a = client.register!
      probes = %w[query run].flat_map do |name|
        [[a, ''], [nil, ' (anon)']].map { |principal, tag| probe(name, principal, tag) }
      end
      failed = probes.reject { |ok, _| ok }
      Kiosk::Redteam::Verdict.new(
        blocked: failed.empty?, skipped: false, status: 404,
        detail: failed.empty? ? '' : "an unregistered verb name answers the wrong thing: #{failed.map(&:last).join(', ')}"
      )
    end

    private

    def probe(name, principal, tag)
      res, body = raw(principal, :post, "/kiosk/#{name}", { name: 'properties' })
      [res.code.to_i == 404 && body['code'].nil?,
       "POST /kiosk/#{name}#{tag} → #{res.code}/#{body['code'].inspect} " \
       '(want 404 with no problem-document code)']
    end
  end

  # The wrong HTTP method on a registered verb draws no route: a plain 404 with no Allow, and the
  # verb never runs.
  class MethodMismatch < Kiosk::Redteam::Scenario
    include RawWire

    PROBES = [
      [:get,  '/kiosk/reserve_room', nil],
      [:post, '/kiosk/my_bookings',  {}]
    ].freeze

    def initialize
      super(name: 'MethodMismatch')
    end

    def call(client, _profile)
      a = client.register!
      probes  = PROBES.map { |method, path, body| probe(a, method, path, body) }
      blocked = probes.all? { |ok, _| ok }
      Kiosk::Redteam::Verdict.new(
        blocked:, skipped: false, status: 404,
        detail: blocked ? '' : "a method mismatch is not answered as a plain 404: #{probes.map(&:last).join('; ')}"
      )
    end

    private

    def probe(principal, method, path, body)
      res, doc = raw(principal, method, path, body)
      ok = res.code.to_i == 404 && res['allow'].nil? && doc['code'].nil?
      [ok, "#{method.to_s.upcase} #{path} → #{res.code}/#{doc['code'].inspect} " \
           "Allow=#{res['allow'].inspect} (want a plain 404, no Allow, no code)"]
    end
  end

  # Today is not probed: the floor is the property's day (Europe/Istanbul), not the runner's.
  class PastStay < Kiosk::Redteam::Scenario
    PAST_IN  = '1900-01-01'
    PAST_OUT = '1900-01-04'
    # Own nights, disjoint from the shared inventory, for the control hold.
    CTL_IN  = (Date.today + 90).to_s.freeze
    CTL_OUT = (Date.today + 93).to_s.freeze

    def initialize
      super(name: 'PastStay')
    end

    def call(client, _profile)
      @client    = client
      @principal = client.register!
      found      = FIND_AVAILABLE.call(client, @principal)
      @failures  = []
      @statuses  = []
      past_availability(found[:prop]['property_id'])
      ctl_room = control_availability(found[:prop]['property_id'], found[:room]['room_type_id'])
      past_hold(found[:room]['room_type_id'])
      control_hold(ctl_room)
      verdict
    end

    private

    def verdict
      Kiosk::Redteam::Verdict.new(blocked: @failures.empty?, skipped: false,
                                  status: @statuses.find { |st| st != 400 } || 400, detail: @failures.join(' | '))
    end

    # Read side: no availability for a past date.
    def past_availability(prop_id)
      resp = @client.query(@principal, name: 'availability', property_id: prop_id, check_in: PAST_IN, check_out: PAST_OUT)
      @statuses << resp.status
      rows = resp.body.is_a?(Array) ? resp.body : []
      unless refusal?(resp)
        @failures << "availability(#{PAST_IN}..#{PAST_OUT}) → HTTP #{resp.status} " \
                     "code=#{error_code(resp).inspect} rows=#{rows.size} " \
                     '(want 400 bad_request naming the earliest bookable night; ZERO rooms either way)'
      end
      listed_nothing(rows)
    end

    def listed_nothing(rows)
      return if rows.empty?

      @failures << "availability(#{PAST_IN}..#{PAST_OUT}) LISTED #{rows.size} room type(s) — " \
                   'there is no room-night in the past to offer'
    end

    # CONTROL for half 1 — a future stay at the same property must still list.
    # Answers the room the control hold books: the first listed, else `fallback`.
    def control_availability(prop_id, fallback)
      resp = @client.query(@principal, name: 'availability', property_id: prop_id, check_in: CTL_IN, check_out: CTL_OUT)
      rows = resp.body.is_a?(Array) ? resp.body : []
      if resp.status != 200 || rows.empty?
        @failures << "CONTROL availability(#{CTL_IN}..#{CTL_OUT}) → HTTP #{resp.status} " \
                     "rows=#{rows.size} (a handler that refused every date would pass the probe above)"
      end
      rows.first ? rows.first['room_type_id'] : fallback
    end

    # Write side: no hold for a past room-night.
    def past_hold(room_id)
      resp = @client.run(@principal, name: 'reserve_room', room_type_id: room_id, check_in: PAST_IN, check_out: PAST_OUT)
      @statuses << resp.status
      return if refusal?(resp)

      @failures << "reserve_room(#{PAST_IN}..#{PAST_OUT}) → HTTP #{resp.status} " \
                   "code=#{error_code(resp).inspect} body=#{JSON.generate(resp.body)[0, 160]} " \
                   '(want 400 bad_request; a 200 here is a sold room-night from last century)'
    end

    # CONTROL: the same call at a future date must hold.
    def control_hold(room_id)
      resp = @client.run(@principal, name: 'reserve_room', room_type_id: room_id, check_in: CTL_IN, check_out: CTL_OUT)
      return if resp.status == 200

      @failures << "CONTROL reserve_room(#{CTL_IN}..#{CTL_OUT}) → HTTP #{resp.status} " \
                   "code=#{error_code(resp).inspect} (the past-date refusal proves nothing " \
                   'if this verb refuses these arguments anyway)'
    end

    # §9.1: 400 bad_request naming a date, read in the property's locale, not this machine's.
    def refusal?(resp)
      detail = resp.body.is_a?(Hash) ? resp.body['detail'].to_s : ''
      resp.status == 400 && error_code(resp) == 'bad_request' &&
        detail.include?('in the past') && detail.match?(/\d{4}-\d{2}-\d{2}/)
    end
  end
end

scenarios = [
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,      # → SKIP (no action waits on a payment)
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,      # → SKIP (no action waits on a payment)
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,       # → SKIP (no action waits on a payment)
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::StolenToken.new,
  Kiosk::Redteam::Scenarios::PrivilegeSelfSelection.new,
  # The claim ceremony's door: the device_authorization request a registered client signs.
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  Kiosk::Redteam::Scenarios::WrongCurrencyPayment.new,      # payment currency ≠ checkout currency
  HotelingScenarios::TamperedPriceCheckout.new,             # forged checkout — below quote
  HotelingScenarios::InflatedTotalCheckout.new,             # forged checkout — total ≠ line sum
  HotelingScenarios::ForgedCheckoutRef.new,                 # forged checkout naming junk → 403, no SQL
  HotelingScenarios::HostileArgShapes.new,                  # boolean/array/object/date shapes → typed 400
  HotelingScenarios::DoubleBookedRoom.new,                  # one room-night, one booking
  HotelingScenarios::UnregisteredVerbIsOrdinaryRefusal.new, # a path naming no verb → 404, not a shim
  HotelingScenarios::MethodMismatch.new,                    # wrong method draws no route → plain 404
  HotelingScenarios::PastStay.new,                          # no availability in the past, no booking into it
  Kiosk::Redteam::Scenarios::MissingKyc.new,                # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,                # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::ForgedKyc.new,                 # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new # → BLOCKED (register PoW ON)
]

# No KYC, and no action waits on a payment; register PoW is on, so RegistrationWithoutPow runs.
EXPECTED_SKIP_NAMES = %w[
  ExpiredKyc
  ForgedKyc
  MissingKyc
  PayForOtherUseSelf
  SpentResourceReuse
  UnpaidGatedAction
].freeze

puts "\n── hoteling redteam battery ──"
puts "  base_url:       #{BASE_URL}"
puts "  pow_difficulty: #{profile.pow_difficulty} (register PoW #{profile.pow_difficulty.to_i.positive? ? 'ON' : 'OFF'})"
puts "  requires_kyc:   #{profile.requires_kyc}"
puts "  scenarios:      #{scenarios.size} (#{EXPECTED_SKIP_NAMES.size} expected skips)"
puts ''

runner  = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile:)
results = runner.run(scenarios)

# report! exits 0 when every attack ran and was blocked, 1 on a breach or nothing run, 2 on unexpected skips.
battery = Kiosk::Redteam::Battery.new
battery.absorb(results)
exit battery.report!(expected_skips: EXPECTED_SKIP_NAMES)
