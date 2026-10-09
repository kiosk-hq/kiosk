# frozen_string_literal: true

# Red-team battery for hoteling: attacks a running server and asserts every attack is refused.
# Usage: SERVER_URL=http://127.0.0.1:3003 bundle exec ruby script/redteam_suite.rb

require "kiosk/redteam"
require "jwt"
require "net/http"
require "securerandom"
require "uri"
require "date"

BASE_URL = ENV.fetch("SERVER_URL")
ISSUER   = BASE_URL

# Clear of today's inventory; every run starts from db:reset.
CHECK_IN  = (Date.today + 30).to_s.freeze
CHECK_OUT = (Date.today + 33).to_s.freeze
NIGHTS    = 3

# First property with a room free for CHECK_IN..CHECK_OUT; earlier beats may exhaust one.
FIND_AVAILABLE = lambda { |client, principal|
  props_resp = client.query(principal, name: "properties")
  all_props  = props_resp.body.is_a?(Array) ? props_resp.body : []
  raise "redteam(hoteling): no properties in catalog" if all_props.empty?

  all_props.each do |p|
    avail_resp = client.query(principal, name: "availability",
      property_id: p["property_id"], check_in: CHECK_IN, check_out: CHECK_OUT)
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
  requires_kyc:   false,  # no KYC gate

  # declared_roles mirrors config/initializers/kiosk.rb: DeviceGrantRoleSelfSelection must name a real role.
  # WrongCurrencyCart probes with a currency other than this one.
  currency:       "eur",
  declared_roles: %w[customer],

  per_user_query: "my_bookings",

  row_id_key:    "booking_id",
  result_id_key: "booking_id",

  create_owned: lambda { |client, principal|
    found = FIND_AVAILABLE.call(client, principal)
    prop  = found[:prop]
    room  = found[:room]

    rsv_resp = client.run(principal, name: "reserve_room",
      property_id:  prop["property_id"],
      room_type_id: room["room_type_id"],
      check_in:     CHECK_IN,
      check_out:    CHECK_OUT)
    raise "redteam(hoteling): reserve_room failed (#{rsv_resp.status}): #{rsv_resp.body.inspect}" \
      unless rsv_resp.status == 200

    booking_id    = rsv_resp.body["booking_id"]
    total_cents   = rsv_resp.body["total_cents"].to_i
    nightly_price = rsv_resp.body["nightly_price_cents"].to_i

    {
      id:            booking_id,
      code:          room["name"],
      total_cents:   total_cents,
      nights:        NIGHTS,
      nightly_price: nightly_price,
    }
  },

  # The scenario injects user_id; reserve_room's schema forbids extra properties, so it is a 400.
  forge_action: "reserve_room",
  forge_args:   lambda { |client, principal_a, _principal_b|
    found = FIND_AVAILABLE.call(client, principal_a)
    prop  = found[:prop]
    room  = found[:room]

    {
      property_id:  prop["property_id"],
      room_type_id: room["room_type_id"],
      check_in:     CHECK_IN,
      check_out:    CHECK_OUT,
    }
  },

  gated_action: "confirm_booking",
  gated_args:   ->(ref) { { booking_id: ref[:id] } },

  # confirm_booking spends nothing, so SpentResourceReuse skips with this reason.
  gated_action_consumes: false,

  # scope=lodging, one line per booking, as reserve_room's pay_hint asks.
  pay_for: lambda { |_client, principal, owned_ref|
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    cart_id   = SecureRandom.uuid

    total_cents      = owned_ref[:total_cents].to_i
    cap_amount_cents = total_cents + 100
    nights           = owned_ref[:nights].to_i.nonzero? || NIGHTS
    nightly_price    = owned_ref[:nightly_price].to_i.nonzero? || (total_cents / nights)

    intent = {
      id:               intent_id,
      user_id:          principal.user_id,
      agent_id:         principal.agent_id,
      iss:              ISSUER,
      scope:            "lodging",
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
      line_items:         [{ qty: nights, price_cents: nightly_price, booking_id: owned_ref[:id] }],
      total_amount_cents: total_cents,
      currency:           "eur",
      exp:                now + 600,
      iat:                now,
    }

    { intent: intent, cart: cart }
  },

  # No KYC — hoteling does not require identity verification
  kyc_valid:   nil,
  kyc_expired: nil,
  kyc_forged:  nil,
)

class TamperedPriceCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "TamperedPriceCart",
      category:    "payment",
      description: "A cart whose total is below the operator's quoted booking price must be rejected at capture",
    )
  end

  def call(client, profile)
    a = client.register!
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)

    # Lower the line price too, so only the quoted-total check can reject it.
    nights        = owned[:nights].to_i.nonzero? || NIGHTS
    lowered_total = owned[:total_cents].to_i - 100
    m[:cart] = m[:cart].merge(
      line_items:         [{ qty: nights, price_cents: (lowered_total / nights), booking_id: owned[:id] }],
      total_amount_cents: lowered_total,
    )
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    # 403 by name: a 401 would mean the cashier never priced this cart.
    verdict_from(resp, expect: 403, detail: "below-quote total settled (HTTP #{resp.status})")
  end
end

class InflatedTotalCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "InflatedTotalCart",
      category:    "payment",
      description: "A cart whose total exceeds the sum of its line items must be rejected at capture",
    )
  end

  def call(client, profile)
    a = client.register!
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)
    # pay_for's line items sum to total_cents; inflate the total only.
    m[:cart] = m[:cart].merge(total_amount_cents: owned[:total_cents].to_i + 50)
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    # 403 by name — see TamperedPriceCart above.
    verdict_from(resp, expect: 403, detail: "total above the line-item sum settled (HTTP #{resp.status})")
  end
end

# confirm_booking's arg is refused by its schema; the signed-cart ref reaches Kiosk::UuidCheck at capture.
class MalformedUuidArg < Kiosk::Redteam::Scenario
  MALFORMED     = ["not-a-uuid", "1; DROP TABLE bookings", ""].freeze
  SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

  def initialize
    super(
      name:        "MalformedUuidArg",
      category:    "input",
      description: "A malformed booking_id — as a confirm_booking arg AND inside a signed cart — must be a typed 400, never a 500",
    )
  end

  def call(client, profile)
    a        = client.register!
    failures = []
    statuses = []

    MALFORMED.each do |junk|
      check(failures, statuses, "confirm_booking(#{junk.inspect})",
            client.run(a, name: "confirm_booking", booking_id: junk), supplied: junk)
      check(failures, statuses, "pay cart booking_id=#{junk.inspect}",
            pay_with_ref(client, a, junk), supplied: junk)
    end

    # CONTROL: a well-formed unknown booking_id gets the cashier's 403, so the 400s above reached it.
    control = pay_with_ref(client, a, "00000000-0000-4000-8000-000000000000")
    unless control.status == 403
      failures << "CONTROL well-formed-but-unknown booking_id → HTTP #{control.status} " \
                  "(want the cashier's 403; a 400 here means the malformed-uuid probes never reached the cashier)"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: failures.empty?,
      skipped: false,
      status:  statuses.find { |s| s != 400 } || 400,
      detail:  failures.join(" | "),
    )
  end

  private

  # `supplied:` discounts the probe's own echoed bytes from the leak scan.
  def check(failures, statuses, label, resp, supplied: nil)
    statuses << resp.status
    scan = Kiosk::Redteam::LeakScan.scan(resp.body, SQL_INTERNALS, supplied: supplied)
    code = resp.body.is_a?(Hash) ? resp.body["code"] : nil
    return if resp.status == 400 && code == "bad_request" && !scan.leak?

    failures << "#{label} → HTTP #{resp.status} code=#{code.inspect}" \
                "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
  end

  # Reserves nothing: the shape check runs before the cashier looks the booking up.
  def pay_with_ref(client, principal, junk)
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    intent = { id: intent_id, user_id: principal.user_id, agent_id: principal.agent_id,
               iss: ISSUER, scope: "lodging", cap_amount_cents: 200, currency: "eur",
               exp: now + 600, iat: now }
    cart = { id: SecureRandom.uuid, intent_mandate_id: intent_id, user_id: principal.user_id,
             agent_id: principal.agent_id, iss: ISSUER,
             line_items: [{ qty: 1, price_cents: 100, booking_id: junk }],
             total_amount_cents: 100, currency: "eur", exp: now + 600, iat: now }
    client.pay(principal, intent:, cart:)
  end
end

# Probes: same nights (B), overlapping nights (A), abutting nights (control), dated hotel_detail.
class DoubleBookedRoom < Kiosk::Redteam::Scenario
  DBL_IN       = (Date.today + 60).to_s.freeze
  DBL_OUT      = (Date.today + 63).to_s.freeze
  DBL_IN_OVL   = (Date.today + 61).to_s.freeze   # overlaps DBL_IN..DBL_OUT
  DBL_OUT_OVL  = (Date.today + 64).to_s.freeze
  DBL_OUT_ADJ  = (Date.today + 66).to_s.freeze   # DBL_OUT..DBL_OUT_ADJ abuts, no overlap

  def initialize
    super(
      name:        "DoubleBookedRoom",
      category:    "inventory",
      description: "A room-night already held must not be reservable again — same or overlapping dates, same or another principal",
    )
  end

  def call(client, profile)
    a = client.register!
    b = client.register!
    failures = []
    statuses = []

    found = free_room(client, a)
    return Kiosk::Redteam::Verdict.new(
      blocked: false, skipped: false, status: 0,
      detail:  "no room available at any property for #{DBL_IN}..#{DBL_OUT} — cannot test the overlap guard",
    ) if found.nil?

    pid = found[:property_id]
    rid = found[:room_type_id]

    held = reserve(client, a, pid, rid, DBL_IN, DBL_OUT)
    statuses << held.status
    failures << "setup: A's first reserve_room → HTTP #{held.status} #{held.body.inspect}" unless held.status == 200

    # 1 — the headline: another principal takes the identical room-night.
    conflict(failures, statuses, "B reserve_room same nights",
             reserve(client, b, pid, rid, DBL_IN, DBL_OUT))

    # 2 — overlap, not equality: one night in common is one night too many.
    conflict(failures, statuses, "A reserve_room overlapping nights",
             reserve(client, a, pid, rid, DBL_IN_OVL, DBL_OUT_OVL))

    # 3 — CONTROL: checkout day is the next guest's check-in day, so this must succeed.
    adjacent = reserve(client, b, pid, rid, DBL_OUT, DBL_OUT_ADJ)
    statuses << adjacent.status
    unless adjacent.status == 200
      failures << "CONTROL abutting nights #{DBL_OUT}..#{DBL_OUT_ADJ} → HTTP #{adjacent.status} " \
                  "(want 200; a checkout day is the next guest's check-in day)"
    end

    # 4 — dated hotel_detail must not offer the taken room; undated must say it is a catalogue.
    dated = client.query(a, name: "hotel_detail", property_id: pid,
                            check_in: DBL_IN, check_out: DBL_OUT)
    statuses << dated.status
    if room_ids(dated).include?(rid)
      failures << "hotel_detail(#{DBL_IN}..#{DBL_OUT}) still offers the taken room_type #{rid}"
    end
    undated = client.query(a, name: "hotel_detail", property_id: pid)
    scope   = detail(undated)["room_types_scope"].to_s
    unless room_ids(undated).include?(rid) && scope.include?("catalogue")
      failures << "undated hotel_detail must still list the full catalogue AND say so " \
                  "(room #{rid} listed: #{room_ids(undated).include?(rid)}, scope: #{scope.inspect})"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: failures.empty?,
      skipped: false,
      status:  statuses.find { |s| s == 409 } || statuses.last.to_i,
      detail:  failures.join(" | "),
    )
  end

  private

  def reserve(client, principal, property_id, room_type_id, check_in, check_out)
    client.run(principal, name: "reserve_room", property_id:, room_type_id:,
                          check_in:, check_out:)
  end

  # Exactly 409 conflict: a 500 also creates no row.
  def conflict(failures, statuses, label, resp)
    statuses << resp.status
    code = resp.body.is_a?(Hash) ? resp.body["code"] : nil
    return if resp.status == 409 && code == "conflict"

    failures << "#{label} → HTTP #{resp.status} code=#{code.inspect} (want 409 conflict)"
  end

  def free_room(client, principal)
    rows = Array(client.query(principal, name: "properties").body)
    rows.each do |p|
      avail = client.query(principal, name: "availability", property_id: p["property_id"],
                                      check_in: DBL_IN, check_out: DBL_OUT)
      first = Array(avail.body).first
      next if first.nil?

      return { property_id: p["property_id"], room_type_id: first["room_type_id"] }
    end
    nil
  end

  # hotel_detail answers a one-row array; empty means no such property.
  def detail(resp)
    Array(resp.body).first || {}
  end

  def room_ids(resp)
    Array(detail(resp)["room_types"]).map { |r| r["room_type_id"] }
  end
end

# Raw requests the redteam Client will not build: unregistered paths and wrong methods.
module RawWire
  # A nil principal sends no bearer.
  def raw(principal, method, path, body = nil)
    uri     = URI("#{BASE_URL}#{path}")
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{principal.token}" if principal
    req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri, headers)
    req.body = JSON.generate(body) if body
    res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
    [res, (JSON.parse(res.body) rescue {})]
  end
end

# Unknown property_id and an unpriceable stay reach hoteling's own guards; the schema refuses the rest.
class HostileArgShapes < Kiosk::Redteam::Scenario
  include RawWire

  # Database vocabulary no error body may carry.
  LEAKS = ["::uuid", "::integer", "::date", "PG::", "22P02", "invalid input syntax",
           "ActiveRecord::", "ActiveModel::", "RangeError"].freeze

  # Clear of the shared inventory and DoubleBookedRoom's window; nothing here books.
  PROBE_IN  = (Date.today + 80).to_s.freeze
  PROBE_OUT = (Date.today + 83).to_s.freeze

  INT_SHAPES  = [true, false, [], {}, [1], { "a" => 1 }, "abc", nil, 1.5, "0x10"].freeze
  DATE_SHAPES = [true, [], {}, nil, 20260901, "nope", "", "2026-02-30", "09/01/2026",
                 "2026-09-01'; --", ["2026-09-01"]].freeze

  def initialize
    super(
      name:        "HostileArgShapes",
      category:    "input",
      description: "Boolean/array/object/junk-integer/unparseable-date values on reserve_room's four arguments, availability's three and search_hotels' four filters are a typed 400 — never a 500, never a wrong answer served as 200",
    )
  end

  def call(client, profile)
    a         = client.register!
    @failures = []
    prop, room = live_pair(client, a)

    # Action path: real JSON types.
    INT_SHAPES.each do |v|
      refused "reserve_room property_id=#{v.inspect}",
              client.run(a, name: "reserve_room", property_id: v, room_type_id: room,
                            check_in: PROBE_IN, check_out: PROBE_OUT),
              supplied: v
      refused "reserve_room room_type_id=#{v.inspect}",
              client.run(a, name: "reserve_room", property_id: prop, room_type_id: v,
                            check_in: PROBE_IN, check_out: PROBE_OUT),
              supplied: v
    end
    DATE_SHAPES.each do |v|
      refused "reserve_room check_in=#{v.inspect}",
              client.run(a, name: "reserve_room", property_id: prop, room_type_id: room,
                            check_in: v, check_out: PROBE_OUT),
              supplied: v
      refused "reserve_room check_out=#{v.inspect}",
              client.run(a, name: "reserve_room", property_id: prop, room_type_id: room,
                            check_in: PROBE_IN, check_out: v),
              supplied: v
    end

    # Query path: junk strings and the two bracket spellings that decode to an Array and a Hash.
    %w[abc true 0x10].each do |v|
      refused "availability property_id=#{v.inspect}",
              client.query(a, name: "availability", property_id: v,
                              check_in: PROBE_IN, check_out: PROBE_OUT),
              supplied: v
    end
    ["nope", "", "2026-09-01'; --"].each do |v|
      refused "availability check_in=#{v.inspect}",
              client.query(a, name: "availability", property_id: prop,
                              check_in: v, check_out: PROBE_OUT),
              supplied: v
    end
    ["nope", "", "2026-02-30", "09/01/2026"].each do |v|
      refused "availability check_out=#{v.inspect}",
              client.query(a, name: "availability", property_id: prop,
                              check_in: PROBE_IN, check_out: v),
              supplied: v
    end
    ["check_in%5B%5D", "check_in%5Bx%5D"].each do |bracket|
      res, doc = raw(a, :get,
                     "/kiosk/availability?property_id=#{prop}&check_out=#{PROBE_OUT}&#{bracket}=#{PROBE_IN}")
      note "availability #{bracket}", res.code.to_i, doc, supplied: [bracket, PROBE_IN]
    end

    # search_hotels filters: integer ranges and enums; a silent miss would answer 200 [].
    beyond_int4 = 2_147_483_648 # one past PostgreSQL `integer`
    %W[abc true 0 9 1.5 0x10 #{beyond_int4}].each do |v|
      refused "search_hotels min_stars=#{v.inspect}",
              client.query(a, name: "search_hotels", min_stars: v), supplied: v
    end
    %W[abc true -1 1.5 #{beyond_int4}].each do |v|
      refused "search_hotels max_price_cents=#{v.inspect}",
              client.query(a, name: "search_hotels", max_price_cents: v), supplied: v
    end
    ["nope", "", "Sultanahmet'; --"].each do |v|
      refused "search_hotels neighbourhood=#{v.inspect}",
              client.query(a, name: "search_hotels", neighbourhood: v), supplied: v
      refused "search_hotels amenity=#{v.inspect}",
              client.query(a, name: "search_hotels", amenity: v), supplied: v
    end

    # CONTROL: well-formed filters still answer 200 with an array.
    filtered = client.query(a, name: "search_hotels", min_stars: 1, max_price_cents: 10_000_000)
    unless filtered.status == 200 && filtered.body.is_a?(Array)
      @failures << "CONTROL well-formed search_hotels filters → HTTP #{filtered.status} " \
                   "#{filtered.body.inspect[0, 80]} (want 200 + an array)"
    end

    # The two that reach hoteling's own guards.
    unknown = client.query(a, name: "availability", property_id: 999_999,
                              check_in: PROBE_IN, check_out: PROBE_OUT)
    unless unknown.status == 404 && body_code(unknown) == "not_found"
      @failures << "unknown property_id → HTTP #{unknown.status} " \
                   "code=#{body_code(unknown).inspect} (want 404/not_found; a 200 [] would " \
                   "assert the hotel exists and merely has no rooms)"
    end

    # Asked from the far end: an old check_in would hit the past-date refusal first.
    refused "reserve_room check_out=\"9999-12-31\" (unpriceable stay)",
            client.run(a, name: "reserve_room", property_id: prop, room_type_id: room,
                          check_in: PROBE_IN, check_out: "9999-12-31"),
            supplied: "9999-12-31"

    # CONTROL: a well-formed call answers 200, so the refusals are not vacuous.
    control = client.query(a, name: "availability", property_id: prop,
                              check_in: PROBE_IN, check_out: PROBE_OUT)
    unless control.status == 200 && control.body.is_a?(Array)
      @failures << "CONTROL well-formed availability → HTTP #{control.status} " \
                   "#{control.body.inspect[0, 80]} (want 200 + an array; the shape probes above " \
                   "prove nothing on an origin that refuses everything)"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: @failures.empty?, skipped: false, status: 400,
      detail:  @failures.join(" | "),
    )
  end

  private

  # A real property/room pair, so only the shape under test is wrong.
  def live_pair(client, principal)
    props = client.query(principal, name: "properties").body
    raise "redteam(hoteling): no properties" unless props.is_a?(Array) && props.any?

    props.each do |p|
      rows = client.query(principal, name: "availability", property_id: p["property_id"],
                                     check_in: PROBE_IN, check_out: PROBE_OUT).body
      return [p["property_id"], rows.first["room_type_id"]] if rows.is_a?(Array) && rows.any?
    end
    raise "redteam(hoteling): no availability for #{PROBE_IN}..#{PROBE_OUT}"
  end

  def body_code(resp) = resp.body.is_a?(Hash) ? resp.body["code"] : nil

  def refused(label, resp, supplied: nil)
    note(label, resp.status, resp.body.is_a?(Hash) ? resp.body : {}, supplied: supplied)
  end

  # `supplied:` discounts the probe's own echoed bytes from the leak scan.
  def note(label, status, doc, supplied: nil)
    scan = Kiosk::Redteam::LeakScan.scan(doc, LEAKS, supplied: supplied)
    return if status == 400 && doc["code"] == "bad_request" && !scan.leak?

    @failures << "#{label} → HTTP #{status} code=#{doc["code"].inspect}" \
                 "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
  end
end

# The two names a caller hunting for a multiplexed endpoint tries first.
class UnregisteredVerbIsOrdinaryRefusal < Kiosk::Redteam::Scenario
  include RawWire

  def initialize
    super(
      name:        "UnregisteredVerbIsOrdinaryRefusal",
      category:    "wire",
      description: "POST /kiosk/query and POST /kiosk/run name no registered verb and no " \
                   "route, so both must be the ordinary 404 any undrawn path gets — bearer " \
                   "or not — never a privileged surface",
    )
  end

  def call(client, profile)
    a = client.register!

    probes = %w[query run].flat_map do |name|
      [[a, ""], [nil, " (anon)"]].map do |principal, tag|
        res, body = raw(principal, :post, "/kiosk/#{name}", { name: "properties" })
        [res.code.to_i == 404 && body["code"].nil?,
         "POST /kiosk/#{name}#{tag} → #{res.code}/#{body["code"].inspect} " \
         "(want 404 with no problem-document code)"]
      end
    end

    Kiosk::Redteam::Verdict.new(
      blocked: probes.all? { |ok, _| ok },
      skipped: false,
      status:  404,
      detail:  probes.all? { |ok, _| ok } ? "" : "an unregistered verb name answers the wrong " \
                                                 "thing: " \
                                                 "#{probes.reject { |ok, _| ok }.map(&:last).join(", ")}",
    )
  end
end

class MethodMismatch < Kiosk::Redteam::Scenario
  include RawWire

  def initialize
    super(
      name:        "MethodMismatch",
      category:    "wire",
      description: "The wrong HTTP method on a registered verb draws no route: a plain 404 " \
                   "with no Allow, and the verb never runs",
    )
  end

  def call(client, profile)
    a = client.register!

    probes = [
      [:get,  "/kiosk/reserve_room", nil],
      [:post, "/kiosk/my_bookings",  {}],
    ].map do |method, path, body|
      res, doc = raw(a, method, path, body)
      ok = res.code.to_i == 404 && res["allow"].nil? && doc["code"].nil?
      [ok, "#{method.to_s.upcase} #{path} → #{res.code}/#{doc["code"].inspect} " \
           "Allow=#{res["allow"].inspect} (want a plain 404, no Allow, no code)"]
    end

    Kiosk::Redteam::Verdict.new(
      blocked: probes.all? { |ok, _| ok },
      skipped: false,
      status:  404,
      detail:  probes.all? { |ok, _| ok } ? "" : "a method mismatch is not answered as a plain " \
                                                 "404: #{probes.map(&:last).join("; ")}",
    )
  end
end

# Today is not probed: the floor is the property's day (Europe/Istanbul), not the runner's.
class PastStay < Kiosk::Redteam::Scenario
  PAST_IN  = "1900-01-01"
  PAST_OUT = "1900-01-04"
  # Own nights, disjoint from the shared inventory, for the control hold.
  CTL_IN  = (Date.today + 90).to_s.freeze
  CTL_OUT = (Date.today + 93).to_s.freeze

  def initialize
    super(
      name:        "PastStay",
      category:    "surface",
      description: "A check_in before today is a typed 400 on BOTH availability and reserve_room — never rooms, never a hold",
    )
  end

  def call(client, profile)
    a        = client.register!
    found    = FIND_AVAILABLE.call(client, a)
    prop_id  = found[:prop]["property_id"]
    room_id  = found[:room]["room_type_id"]
    failures = []
    statuses = []

    # Read side: no availability for a past date.
    past_avail = client.query(a, name: "availability",
                              property_id: prop_id, check_in: PAST_IN, check_out: PAST_OUT)
    statuses << past_avail.status
    rows = past_avail.body.is_a?(Array) ? past_avail.body : []
    unless refusal?(past_avail)
      failures << "availability(#{PAST_IN}..#{PAST_OUT}) → HTTP #{past_avail.status} " \
                  "code=#{error_code(past_avail).inspect} rows=#{rows.size} " \
                  "(want 400 bad_request naming the earliest bookable night; ZERO rooms either way)"
    end
    unless rows.empty?
      failures << "availability(#{PAST_IN}..#{PAST_OUT}) LISTED #{rows.size} room type(s) — " \
                  "there is no room-night in the past to offer"
    end

    # CONTROL for half 1 — a future stay at the same property must still list.
    ctl_avail = client.query(a, name: "availability",
                             property_id: prop_id, check_in: CTL_IN, check_out: CTL_OUT)
    ctl_rows  = ctl_avail.body.is_a?(Array) ? ctl_avail.body : []
    if ctl_avail.status != 200 || ctl_rows.empty?
      failures << "CONTROL availability(#{CTL_IN}..#{CTL_OUT}) → HTTP #{ctl_avail.status} " \
                  "rows=#{ctl_rows.size} (a handler that refused every date would pass the probe above)"
    end

    # Write side: no hold for a past room-night.
    past_hold = client.run(a, name: "reserve_room", property_id: prop_id, room_type_id: room_id,
                                                    check_in: PAST_IN, check_out: PAST_OUT)
    statuses << past_hold.status
    unless refusal?(past_hold)
      failures << "reserve_room(#{PAST_IN}..#{PAST_OUT}) → HTTP #{past_hold.status} " \
                  "code=#{error_code(past_hold).inspect} body=#{JSON.generate(past_hold.body)[0, 160]} " \
                  "(want 400 bad_request; a 200 here is a sold room-night from last century)"
    end

    # CONTROL: the same call at a future date must hold.
    ctl_room = ctl_rows.first ? ctl_rows.first["room_type_id"] : room_id
    ctl_hold = client.run(a, name: "reserve_room", property_id: prop_id, room_type_id: ctl_room,
                                                   check_in: CTL_IN, check_out: CTL_OUT)
    unless ctl_hold.status == 200
      failures << "CONTROL reserve_room(#{CTL_IN}..#{CTL_OUT}) → HTTP #{ctl_hold.status} " \
                  "code=#{error_code(ctl_hold).inspect} (the past-date refusal proves nothing " \
                  "if this verb refuses these arguments anyway)"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: failures.empty?,
      skipped: false,
      status:  statuses.find { |st| st != 400 } || 400,
      detail:  failures.join(" | "),
    )
  end

  private

  # §9.1: 400 bad_request naming a date, read in the property's locale, not this machine's.
  def refusal?(resp)
    detail = resp.body.is_a?(Hash) ? resp.body["detail"].to_s : ""
    resp.status == 400 && error_code(resp) == "bad_request" &&
      detail.include?("in the past") && detail.match?(/\d{4}-\d{2}-\d{2}/)
  end
end

scenarios = [
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,      # C2 — headline
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,      # C3 — skips: nothing is spent
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::PrivilegeSelfSelection.new,
  # The claim ceremony's door: the unauthenticated device_authorization request.
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  Kiosk::Redteam::Scenarios::WrongCurrencyCart.new,                                  # cashier check — currency
  TamperedPriceCart.new,                                  # cashier check — below quote
  InflatedTotalCart.new,                                  # cashier check — total ≠ line sum
  MalformedUuidArg.new,                                   # junk uuid → typed 400, no 500
  HostileArgShapes.new,                                   # boolean/array/object/date shapes → typed 400
  DoubleBookedRoom.new,                                   # one room-night, one booking
  UnregisteredVerbIsOrdinaryRefusal.new,                  # a path naming no verb → 404, not a shim
  MethodMismatch.new,                                     # wrong method draws no route → plain 404
  PastStay.new,                                           # no availability in the past, no booking into it
  Kiosk::Redteam::Scenarios::MissingKyc.new,              # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,              # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::ForgedKyc.new,               # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new,  # → BLOCKED (register PoW ON)
]

# No KYC, and confirm_booking spends nothing; register PoW is on, so RegistrationWithoutPow runs.
EXPECTED_SKIP_NAMES = %w[
  ExpiredKyc
  ForgedKyc
  MissingKyc
  SpentResourceReuse
].freeze

puts "\n── hoteling redteam battery ──"
puts "  base_url:       #{BASE_URL}"
puts "  pow_difficulty: #{profile.pow_difficulty} (register PoW #{profile.pow_difficulty.to_i > 0 ? "ON" : "OFF"})"
puts "  requires_kyc:   #{profile.requires_kyc}"
puts "  scenarios:      #{scenarios.size} (#{EXPECTED_SKIP_NAMES.size} expected skips)"
puts ""

runner  = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile:)
results = runner.run(scenarios)

# report! exits 0 when every attack ran and was blocked, 1 on a breach or nothing run, 2 on unexpected skips.
battery = Kiosk::Redteam::Battery.new
battery.absorb(results)
exit battery.report!(expected_skips: EXPECTED_SKIP_NAMES)
