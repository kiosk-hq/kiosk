# frozen_string_literal: true

# hoteling redteam battery
#
# Exercises the hoteling chain: register (PoW-gated) → no KYC → reserve_room →
# pay → confirm_booking (2-gate: ownership / payment). Headline scenarios:
#   C2  PayForOtherUseSelf  — B pays for A's booking, B tries confirm_booking
#   C3  SpentResourceReuse  — re-confirm an already-confirmed booking
#
# Three local cashier-check beats attack ValidatingBookingProvider (the
# monetary check run at capture, before StubPsp settles):
#   WrongCurrencyCart  — pay own booking in usd → 403
#   TamperedPriceCart  — pay below the operator's quoted booking price → 403
#   InflatedTotalCart  — cart total ≠ sum of its line items → 403
# Plus two input-shape beats, one date beat and one inventory beat:
#   MalformedUuidArg   — a junk booking_id, as an arg AND inside a signed cart,
#                        is a typed 400 with no SQL internals — never a 500
#   HostileArgShapes   — every hostile SHAPE (boolean, array, object, junk
#                        integer, unparseable and out-of-horizon date) on the
#                        integer and date arguments is a typed 400 too
#   PastStay           — a check_in before today is a typed 400 on BOTH
#                        availability and reserve_room: never rooms, never a
#                        hold
#   DoubleBookedRoom   — a room-night already held cannot be reserved again by
#                        anyone, on the same or overlapping dates → 409
#
# And two beats that are only expressible after the 0.4 cutover:
#   RetiredWire        — POST /kiosk/query and POST /kiosk/run are the ordinary
#                        404 / verb_not_found an AUTHENTICATED caller gets, and
#                        401 / unauthenticated without a bearer (auth precedes
#                        verb dispatch; both are probed): the multiplexed pair
#                        was DELETED, so there is no privileged endpoint left,
#                        no compatibility payload, and no second conformance
#                        surface to attack.
#   MethodMismatch     — a GET at an action's path is 405 / method_not_allowed
#                        with `Allow: POST`, never a silent 404 an assistant
#                        would read as "this operator cannot do that".
#
# THE 0.4 WIRE, throughout: a query is `GET <endpoint>/<query-name>` with its
# arguments in the query string, an action is `POST <endpoint>/<action-name>`
# with its arguments as the JSON body, a success body IS the result (a bare
# array from a non-paginating query, the action's own object from an action),
# and an error is an RFC 9457 problem document whose branch point is the
# TOP-LEVEL `code` (`message` became `detail`).
#
# KYC scenarios are SKIPPED (hoteling has no KYC). RegistrationWithoutPow RUNS:
# register PoW is ON (registration_pow_count=1), so a missing/bad register proof
# must be rejected.
#
# Usage (from kiosk-demo-hoteling/):
#   SERVER_URL=http://127.0.0.1:3003 KIOSK_ISSUER=http://127.0.0.1:3003 \
#   bundle exec ruby script/redteam_suite.rb
#
# Exits non-zero if any applicable scenario reports a BREACH or if the
# expected skip set does not match (catches profile typos that disable gates).

require "kiosk/redteam"
require "jwt"
require "net/http"
require "securerandom"
require "uri"
require "date"

BASE_URL = ENV.fetch("SERVER_URL", "http://127.0.0.1:3003")
ISSUER   = ENV.fetch("KIOSK_ISSUER", BASE_URL)

# Dates far enough in the future to avoid conflicts with existing data.
# Each redteam run starts with a clean DB (demo:setup), so these are stable.
CHECK_IN  = (Date.today + 30).to_s.freeze
CHECK_OUT = (Date.today + 33).to_s.freeze
NIGHTS    = 3

# Helper: iterate all properties to find first available room for CHECK_IN..CHECK_OUT.
# Multiple scenarios run sequentially against the same DB; earlier scenarios may
# exhaust room types at one property, so we iterate until availability is found.
FIND_AVAILABLE = lambda { |client, principal|
  props_resp = client.query(principal, name: "properties")
  # A non-paginating query answers a BARE ARRAY — the rows themselves.
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

# ── Profile ───────────────────────────────────────────────────────────────────

profile = Kiosk::Redteam::Profile.new(
  # register PoW is ON (registration_pow_count=1): a positive difficulty makes
  # RegistrationWithoutPow RUN (a missing/bad register proof must be rejected).
  # The Client ignores the magnitude (PoW solving is driven by the server's 402
  # challenges); only "> 0" matters here.
  pow_difficulty: 1,
  requires_kyc:   false,  # no KYC gate

  # ── declared_roles — DeviceGrantRoleSelfSelection ────────────────────────
  # `Kiosk.configuration.roles` for this origin (config/initializers/kiosk.rb).
  # The claim ceremony's beat must name a role this origin ACTUALLY declares:
  # an invented one is refused even by an implementation that lets a DECLARED
  # role through, so a battery probing only an invented role stays green over a
  # real hole. The scenario also derives one off the wire, so a stale list here
  # weakens the probe rather than emptying it.
  declared_roles: %w[customer],

  # ── per-user query — CrossTenantRead ─────────────────────────────────────
  per_user_query: "my_bookings",

  # ── row_id_key / result_id_key ────────────────────────────────────────────
  # Query rows (my_bookings) carry "booking_id" (the same name confirm_booking takes).
  # The reserve_room action answers its OWN object, whose "booking_id" is a
  # top-level member — 0.4 retired the `{value: …}` wrapper.
  row_id_key:    "booking_id",
  result_id_key: "booking_id",

  # ── create_owned ─────────────────────────────────────────────────────────
  # Browse properties → check availability → reserve_room.
  # Iterates all properties to avoid exhausting a single property's room types.
  # Returns { id: booking_id, code: room_type_name, total_cents:, nights: }.
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

  # ── forge_action / forge_args — ForgedUserId ─────────────────────────────
  # B calls reserve_room with user_id: A.user_id injected. Since 0.4 the wire
  # itself REFUSES it: `reserve_room` publishes `additionalProperties: false`
  # and does not declare `user_id`, so the injected principal is a typed 400
  # before the handler runs. (Through 0.3 the argument was accepted and the
  # handler derived the owner from the GUC instead; the generic scenario accepts
  # either — a 4xx refusal, or a 200 whose row never surfaces under A.)
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

  # ── gated_action / gated_args — UnpaidGatedAction, C2, C3 ───────────────
  gated_action: "confirm_booking",
  gated_args:   ->(ref) { { booking_id: ref[:id] } },

  # ── pay_for — MandatePrincipalSwap, MandateReplay, C2, C3 ───────────────
  # Shape mirrors script/hoteling_flow.rb: scope=lodging, line_items with
  # sku + qty + booking_id as required by Gate-2 of confirm_booking.
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
      line_items:         [{ sku: owned_ref[:code], qty: nights, price_cents: nightly_price, booking_id: owned_ref[:id] }],
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

# ── Local scenarios: the cashier check (ValidatingBookingProvider) ────────────
# The generic battery proves ownership/payment gates; these three prove the
# operator counts what lands on the counter — currency, single booking, total.
# Each uses the AGENT'S OWN booking (no cross-ownership needed): the check is
# monetary only, so an own-booking cart at the wrong price/currency is the
# clean isolation of the cashier check.

# A chain-consistent cart in the wrong currency must not settle: the engine
# only enforces intent/cart/payment agreement, the OPERATOR prices in EUR.
class WrongCurrencyCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "WrongCurrencyCart",
      category:    "payment",
      description: "A usd-denominated (chain-consistent) cart at a EUR operator must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-cur-a", profile:)
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)
    m[:intent] = m[:intent].merge(currency: "usd")
    m[:cart]   = m[:cart].merge(currency: "usd")
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    verdict_from(resp, detail: "usd cart settled at a EUR operator (HTTP #{resp.status})")
  end
end

# A total below the operator's quoted booking price must be caught even though
# the mandate chain is internally consistent (payment mirrors the cart).
class TamperedPriceCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "TamperedPriceCart",
      category:    "payment",
      description: "A cart whose total is below the operator's quoted booking price must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-price-a", profile:)
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)

    # Pay 100c less than quoted, keeping the priced line consistent with the
    # lowered total so ONLY the quoted-total check can reject it.
    nights        = owned[:nights].to_i.nonzero? || NIGHTS
    lowered_total = owned[:total_cents].to_i - 100
    m[:cart] = m[:cart].merge(
      line_items:         [{ sku: owned[:code], qty: nights, price_cents: (lowered_total / nights), booking_id: owned[:id] }],
      total_amount_cents: lowered_total,
    )
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    verdict_from(resp, detail: "below-quote total settled (HTTP #{resp.status})")
  end
end

# Correct priced lines but an inflated total (still within the intent cap,
# payment mirrors the cart) must be caught by the line-sum consistency check.
class InflatedTotalCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "InflatedTotalCart",
      category:    "payment",
      description: "A cart whose total exceeds the sum of its line items must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-total-a", profile:)
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)
    # pay_for's line items sum to total_cents; inflate the total only.
    m[:cart] = m[:cart].merge(total_amount_cents: owned[:total_cents].to_i + 50)
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    verdict_from(resp, detail: "total above the line-item sum settled (HTTP #{resp.status})")
  end
end

# A malformed booking_id must come back as a TYPED 400, never a 500.
# Two surfaces, one guard (UuidCheck): confirm_booking's `booking_id` arg, and the
# `{"booking_id":…}` reference inside a signed cart mandate that the cashier
# prices at capture. Without the guard, Postgres raises InvalidTextRepresentation
# on the `::uuid` cast — not a Kiosk error, so it escapes as a raw 500 with the
# PG message attached, and on the PAY path a 500 is the worst possible answer
# because an assistant cannot tell it from "the charge may have gone through".
#
# Asserts three properties, not one: HTTP 400 (a client mistake reported as such),
# the problem document's top-level `code == "bad_request"` (typed, so an
# assistant can branch on it), and no SQL internals anywhere in the body. A
# generic `blocked?` verdict would accept a 403 or a 401 here, so this scenario
# builds its Verdict directly.
#
# Since 0.4 the ARG-shaped probes are refused one layer EARLIER — `booking_id`
# declares `format: "uuid"` and `input_schema` is validated on every call — so
# that half now comes from the declared contract rather than from UuidCheck
# inside the handler. Same status, same code, same no-leak property; the guard
# behind it still stands for what reaches it, which is the signed-cart probe
# below that no input_schema covers.
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
    a        = register_principal(client, name: "redteam-uuid-a", profile:)
    failures = []
    statuses = []

    MALFORMED.each do |junk|
      check(failures, statuses, "confirm_booking(#{junk.inspect})",
            client.run(a, name: "confirm_booking", booking_id: junk), supplied: junk)
      check(failures, statuses, "pay cart booking_id=#{junk.inspect}",
            pay_with_ref(client, a, junk), supplied: junk)
    end

    # CONTROL — without it the pay assertion above could pass vacuously: any 400
    # `bad_request` raised EARLIER in the pay pipeline (mandate chain, scope,
    # amounts) would satisfy it without the cashier ever being reached. A
    # WELL-FORMED but nonexistent booking_id must therefore come back as the
    # cashier's own "booking not found" 403 — proving the request really does
    # get that far, and that the shape check is not swallowing the authz answer.
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

  # `supplied:` is what this probe put on the wire, and it is what stops the
  # leak assertion being decided by the attacker. hoteling answers a bad
  # `booking_id` by naming it back, so the bytes scanned for SQL_INTERNALS are
  # partly the probe's own; a junk id spelling `PG::` would otherwise be
  # reported as a BREACH on its own echo, under a runner whose prose says a
  # BREACH means "fix the app, not the scenario". The default is nil, which
  # discounts nothing: forgetting to declare risks a FALSE BREACH, never a
  # missed leak.
  def check(failures, statuses, label, resp, supplied: nil)
    statuses << resp.status
    scan = Kiosk::Redteam::LeakScan.scan(resp.body, SQL_INTERNALS, supplied: supplied)
    code = resp.body.is_a?(Hash) ? resp.body["code"] : nil
    return if resp.status == 400 && code == "bad_request" && !scan.leak?

    failures << "#{label} → HTTP #{resp.status} code=#{code.inspect}" \
                "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
  end

  # Deliberately reserves NOTHING: the shape guard runs before the cashier takes
  # a connection, so a cart naming a junk booking_id needs no booking behind it —
  # and this scenario therefore consumes no room from the shared availability the
  # other scenarios draw on.
  def pay_with_ref(client, principal, junk)
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    intent = { id: intent_id, user_id: principal.user_id, agent_id: principal.agent_id,
               iss: ISSUER, scope: "lodging", cap_amount_cents: 200, currency: "eur",
               exp: now + 600, iat: now }
    cart = { id: SecureRandom.uuid, intent_mandate_id: intent_id, user_id: principal.user_id,
             agent_id: principal.agent_id, iss: ISSUER,
             line_items: [{ sku: "any-room", qty: 1, price_cents: 100, booking_id: junk }],
             total_amount_cents: 100, currency: "eur", exp: now + 600, iat: now }
    client.pay(principal, intent:, cart:)
  end
end

# Two principals must not be able to hold the same room-night.
# A `reserve_room` that validates only room-type↔property and
# check_out > check_in — never re-applying the overlap exclusion its OWN
# `availability` query defines, with no database constraint behind it — lets A
# and B both reserve, and both PAY for, one physical room, leaving the operator
# owing two guests one bed. Nothing else reaches it: every other scenario picks
# its room FROM availability, where the exclusion is applied, so none of them
# ever asks for a room that is gone.
#
# Four probes, because the interesting failures sit on both sides of the guard:
#   1. same nights, DIFFERENT principal        → 409 (the headline: two settlements, one bed)
#   2. OVERLAPPING nights, SAME principal      → 409 (overlap is a range test, not equality)
#   3. ABUTTING nights (checkout day == next check-in day) → 200 (the guard must
#      not be over-broad: a hotel does sell that bed to the next guest)
#   4. hotel_detail for those dates omits the taken room type, while the
#      undated call still lists it and SAYS the list is a catalogue
#
# It uses its own dates, deliberately disjoint from CHECK_IN..CHECK_OUT, so it
# neither consumes nor depends on the inventory the other scenarios share.
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
    a = register_principal(client, name: "redteam-dbl-a", profile:)
    b = register_principal(client, name: "redteam-dbl-b", profile:)
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

    # 3 — POSITIVE CONTROL. Without it probes 1-2 would pass against a handler
    # that simply refused every reservation. Check-out day is the next guest's
    # check-in day, so this must still succeed.
    adjacent = reserve(client, b, pid, rid, DBL_OUT, DBL_OUT_ADJ)
    statuses << adjacent.status
    unless adjacent.status == 200
      failures << "CONTROL abutting nights #{DBL_OUT}..#{DBL_OUT_ADJ} → HTTP #{adjacent.status} " \
                  "(want 200; a checkout day is the next guest's check-in day)"
    end

    # 4 — the other way in: hotel_detail listed every room type with no date and
    # no booking filter, so an assistant going search → hotel_detail →
    # reserve_room read a catalogue as if it were an offer.
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

  # A 409 `conflict` — not merely "not 200": a 500 also fails to create the row,
  # and would satisfy any weaker assertion while telling an assistant nothing.
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

  # hotel_detail answers a ONE-ROW ARRAY: it is a query, and a query
  # that does not paginate answers rows. `.first` is the whole unwrap, and an
  # EMPTY array — no property with that id — falls through to `{}` here rather
  # than needing a 404 branch.
  def detail(resp)
    Array(resp.body).first || {}
  end

  def room_ids(resp)
    Array(detail(resp)["room_types"]).map { |r| r["room_type_id"] }
  end
end

# ── The shape of the wire itself — two beats the cutover made expressible ─────
#
# Both dial paths and methods the redteam Client will not construct (it only
# ever builds a legal per-verb call), so they issue one raw request each. They
# stage nothing and touch no inventory: the point is what the ROUTER answers,
# not what any handler does.
module RawWire
  # One raw request under the given principal's bearer.
  #
  # A NIL principal is the ANONYMOUS probe and is a different question,
  # not a degenerate case of the same one: the wire resolves the caller BEFORE it
  # looks the verb up, so what an unauthenticated request gets at a retired path
  # is 401, never the 404 an authenticated one gets.
  # @return [Array(Net::HTTPResponse, Hash)] the response and its parsed body
  def raw(principal, method, path, body = nil)
    uri     = URI("#{BASE_URL}#{path}")
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{principal.token}" if principal
    req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri, headers)
    req.body = JSON.generate(body) if body
    res = Net::HTTP.new(uri.host, uri.port).request(req)
    [res, (JSON.parse(res.body) rescue {})]
  end
end

# THE STANDING HOSTILE-SHAPE BEAT.
#
# Postgres does free shape-checking on wire arguments and ActiveRecord does not.
# Interpolate `property_id`/`check_in`/`check_out` into `::integer`/`::date`
# casts and junk RAISES, which the handler turns into a typed refusal; hand the
# same value to ActiveRecord and `where(property_id: "abc")` silently CASTS to
# `= 0` and `where(property_id: true)` to `= 1` — a wrong answer delivered as
# success. The guards in `app/operations/wire_arguments.rb` are what hold the
# refusal, and this is the standing beat that re-sends the hostile shapes on
# every run so they cannot quietly stop firing.
#
# WHICH LAYER ANSWERS THESE TODAY, measured rather than assumed, because it
# changes what the beat is worth. Every SHAPE probe below is currently refused
# by the ENGINE — `input_schema` declares `property_id` an integer and `check_in`
# a `format: "date"` string, and 0.4 validates both on every call, so a boolean,
# an array, an object or `"abc"` never reaches the handler at all. So this beat
# does NOT prove hoteling's own guards fire; it pins the CONTRACT an assistant
# depends on (a typed 400, no 5xx, no wrong answer served as a 200) across both
# layers, and it goes red if either one stops holding — an engine that stops
# validating, or a descriptor that widens a type or drops
# `additionalProperties: false`.
#
# TWO PROBES DO REACH HOTELING'S OWN CODE, and they are here for exactly that
# reason:
#   • an unknown `property_id` is `404 not_found` and NOT `200 []`
#     ({WireArguments.existing_property}) — the empty list would assert the
#     hotel exists and merely has no rooms;
#   • a stay nobody can price is a typed 400 and not a crash: `check_in:
#     "0000-01-01"` is a well-formed date the schema accepts, and the
#     739,000-night stay it asks for overflows `bookings.total_cents` (a 4-byte
#     integer) with `ActiveModel::RangeError`, which the wire would answer
#     `500 action_failed`.
#
# WHAT IS PROBED, NAMED RATHER THAN CLAIMED. A summary sentence — «every
# argument its verbs take» — is unverifiable, and goes false the moment an
# argument is added or a constant is passed to every call site instead of being
# varied. The claim is therefore an enumeration, checkable against this method
# rather than believed:
#
#   reserve_room   property_id, room_type_id  (INT_SHAPES)
#                  check_in, check_out        (DATE_SHAPES)
#   availability   property_id, check_in, check_out (the string spellings a
#                  query can express, plus the two BRACKET spellings)
#   search_hotels  min_stars, max_price_cents (junk + out-of-range integers +
#                                              one past int4)
#                  neighbourhood, amenity     (off-enum strings)
#
# An argument NOT in that list is not covered here — say so by extending the
# list, never by widening the sentence.
class HostileArgShapes < Kiosk::Redteam::Scenario
  include RawWire

  # An error body must never carry the database's own vocabulary, re-asserted
  # here because these probes are the ones most likely to reach a cast.
  LEAKS = ["::uuid", "::integer", "::date", "PG::", "22P02", "invalid input syntax",
           "ActiveRecord::", "ActiveModel::", "RangeError"].freeze

  # Far enough out that nothing here competes with the shared inventory the
  # other beats draw on — deliberately clear of DoubleBookedRoom's +60..+66
  # window. Nothing below is expected to succeed, so nothing is consumed either.
  PROBE_IN  = (Date.today + 80).to_s.freeze
  PROBE_OUT = (Date.today + 83).to_s.freeze

  # The five families the row names, per argument type.
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
    a         = register_principal(client, name: "redteam-shapes", profile:)
    @failures = []
    prop, room = live_pair(client, a)

    # ── the ACTION path: real JSON types ────────────────────────────────────
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
      # …and the SAME shapes on `check_out`. It used to be a frozen constant on
      # every call site here, so the second half of the stay was pinned by
      # nothing: a descriptor that widened `check_out` to an untyped string, or
      # a guard that stopped parsing it, would have left this beat green.
      refused "reserve_room check_out=#{v.inspect}",
              client.run(a, name: "reserve_room", property_id: prop, room_type_id: room,
                            check_in: PROBE_IN, check_out: v),
              supplied: v
    end

    # ── the QUERY path: everything is a string on the wire, so the hostile
    # shapes an assistant can still express are junk scalars and the two
    # BRACKET spellings that decode to an Array and a Hash. ─────────────────
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

    # ── search_hotels' FILTERS, which no beat probed at all ─────────────────
    #
    # Two are declared integers with a range (`min_stars` 1..5,
    # `max_price_cents` >= 0) and two are declared string ENUMS
    # (`neighbourhood`, `amenity`). WHICH LAYER ANSWERS WHICH, named rather than
    # assumed:
    #
    #   * the two INTEGERS are refused on SHAPE twice and on RANGE once, and the
    #     split is measured rather than assumed. The decoder coerces a query
    #     string through `Integer(v, 10)` and the handler re-reads it through
    #     {WireArguments.integer}, which is the same call (read with a bare
    #     `.to_s.to_i` instead, `abc` would floor to 0 and `1.5` to 1, leaving
    #     the DECLARATION as the whole refusal). The POLICY range —
    #     `min_stars` 1..5, `max_price_cents` >= 0 — is the schema's alone; no
    #     handler line re-checks it, and none should: those are house rules, not
    #     facts about a column. WATCHED FAIL, run and restored: drop `min_stars`'
    #     declared `type` and the four SHAPE probes below (`abc`, `true`, `1.5`,
    #     `0x10`) stay 400 off the second layer, while `0` and `9` answer 200 —
    #     `minimum`/`maximum` stop applying to a value that is no longer declared
    #     a number.
    #   * MAGNITUDE is the third axis and it IS re-checked in the handler
    #     both filters pass `max: WireArguments::MAX_INT4`, so a
    #     value past PostgreSQL `integer` is a typed 400 from the schema layer
    #     AND from the guard behind it. Without it the pair would be safe only
    #     by coincidence — `min_stars` only because its descriptor declares
    #     `maximum: 5` (it
    #     reaches `stars.gteq(…)`, which RAISES `ActiveModel::RangeError` casting
    #     the comparison), and `max_price_cents` only because
    #     {Property.from_price_cents} is an `Arel::Nodes::Grouping` carrying no
    #     int4 type, one denormalisation away from the same 500. WATCHED FAIL,
    #     run and restored: drop the `maximum:` from `max_price_cents`' descriptor
    #     AND the `max:` from its call site and the BEYOND_INT4 probe below comes
    #     back 200 with rows, which is this beat's whole point — a filter the
    #     origin could not represent, answered as though it had.
    #   * the two ENUMS are still one layer: `neighbourhood` and `amenity` are
    #     read with a bare `.to_s` and fed to a `where`/`offering`, so the
    #     schema's `enum` is the only thing that refuses an off-list value.
    #
    # Which is precisely why all four need a standing probe: a filter that
    # silently matched nothing would answer `200 []` — «no hotel is like that»
    # in reply to a question the origin never understood.
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

    # The filters' own CONTROL: a well-formed filter pair must still answer 200
    # with an array, or the refusals above prove nothing about search_hotels.
    filtered = client.query(a, name: "search_hotels", min_stars: 1, max_price_cents: 10_000_000)
    unless filtered.status == 200 && filtered.body.is_a?(Array)
      @failures << "CONTROL well-formed search_hotels filters → HTTP #{filtered.status} " \
                   "#{filtered.body.inspect[0, 80]} (want 200 + an array)"
    end

    # ── the two that reach hoteling's OWN guards ────────────────────────────
    unknown = client.query(a, name: "availability", property_id: 999_999,
                              check_in: PROBE_IN, check_out: PROBE_OUT)
    unless unknown.status == 404 && body_code(unknown) == "not_found"
      @failures << "T-090 unknown property_id → HTTP #{unknown.status} " \
                   "code=#{body_code(unknown).inspect} (want 404/not_found; a 200 [] would " \
                   "assert the hotel exists and merely has no rooms)"
    end

    # The unpriceable stay, ASKED FROM THE FAR END. A century-ago `check_in`
    # with a normal check_out is refused by {WireArguments.past_stay} FIRST —
    # still a typed 400, so the assertion would keep passing while never
    # reaching the guard it exists for. A near check_in with a check_out at the
    # end of the calendar asks the same question (a stay whose total overflows
    # `bookings.total_cents`) from the side the past-date floor does not stand
    # on.
    refused "reserve_room check_out=\"9999-12-31\" (unpriceable stay, K-968)",
            client.run(a, name: "reserve_room", property_id: prop, room_type_id: room,
                          check_in: PROBE_IN, check_out: "9999-12-31"),
            supplied: "9999-12-31"

    # ── CONTROL ─────────────────────────────────────────────────────────────
    #
    # Without it every assertion above could pass vacuously on an origin that
    # refuses EVERYTHING — a broken bearer, a wrong verb name, a dead handler.
    # A well-formed call must still answer 200 with a list.
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

  # A property/room-type pair that really exists, so the ONLY thing wrong with
  # each probe is the shape under test.
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

  # `supplied:` is what this probe put on the wire, and it is what stops the
  # leak assertion being decided by the attacker. hoteling names the value it
  # got in most of these refusals — `property_id "abc" is not an integer`,
  # `invalid check_in/check_out: …` — so the bytes scanned for LEAKS are partly
  # the probe's own, and a value spelling `PG::` would otherwise be reported as
  # a BREACH on its own echo, under a runner whose prose says a BREACH means
  # "fix the app, not the scenario". The default is nil, which discounts
  # nothing: forgetting to declare risks a FALSE BREACH, never a missed leak.
  def note(label, status, doc, supplied: nil)
    scan = Kiosk::Redteam::LeakScan.scan(doc, LEAKS, supplied: supplied)
    return if status == 400 && doc["code"] == "bad_request" && !scan.leak?

    @failures << "#{label} → HTTP #{status} code=#{doc["code"].inspect}" \
                 "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
  end
end

# The 0.3 multiplexed pair was DELETED, not tombstoned. `POST
# /kiosk/query` now reaches the per-verb controller as a verb literally named
# "query", which nobody registered, so it answers the ordinary 404 an
# AUTHENTICATED caller gets — no privileged endpoint left, no compatibility
# payload keeping the 0.3 argument channel alive, and no second conformance
# surface to attack.
#
# BOTH CALLERS ARE PROBED, and that is the whole point of the qualifier above.
# `VerbController#serve` resolves the identity BEFORE it looks the verb up, so a
# caller with no bearer never reaches the registry lookup that produces the 404 —
# it is answered 401 `unauthenticated`, exactly as it would be at any other name.
# A beat that dialled only WITH a bearer would let prose say the 404 flatly while
# nothing tested the anonymous case.
#
# A deprecation shim here is exactly what an attacker would reach for, because
# it takes the verb name from the BODY, where no route constraint and no
# input_schema can see it.
class RetiredWire < Kiosk::Redteam::Scenario
  include RawWire

  def initialize
    super(
      name:        "RetiredWire",
      category:    "wire",
      description: "The retired 0.3 endpoints POST /kiosk/query and POST /kiosk/run must be the " \
                   "ordinary 404 an authenticated caller gets — and 401 without a bearer — never a " \
                   "compatibility surface",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-retired-wire", profile:)

    probes = %w[query run].flat_map do |name|
      [[a, 404, "verb_not_found", ""], [nil, 401, "unauthenticated", " (anon)"]]
        .map do |principal, want_status, want_code, tag|
        res, body = raw(principal, :post, "/kiosk/#{name}", { name: "properties" })
        [res.code.to_i == want_status && body["code"] == want_code,
         "POST /kiosk/#{name}#{tag} → #{res.code}/#{body["code"].inspect} " \
         "(want #{want_status}/#{want_code.inspect})"]
      end
    end

    Kiosk::Redteam::Verdict.new(
      blocked: probes.all? { |ok, _| ok },
      skipped: false,
      status:  404,
      detail:  probes.all? { |ok, _| ok } ? "" : "a retired 0.3 endpoint answers the wrong " \
                                                 "thing: " \
                                                 "#{probes.reject { |ok, _| ok }.map(&:last).join(", ")}",
    )
  end
end

# A GET at an action's path is 405 with `Allow: POST`, never a silent 404. The
# resource EXISTS; answering 404 would be a lie about it, and an assistant that
# read that 404 as "this operator cannot do that" would abandon a verb it could
# have called correctly. Probed in BOTH directions, because the fork is
# symmetric: a GET at the action `reserve_room`, and a POST at the query
# `my_bookings`.
class MethodMismatch < Kiosk::Redteam::Scenario
  include RawWire

  def initialize
    super(
      name:        "MethodMismatch",
      category:    "wire",
      description: "The wrong HTTP method on a registered verb must be 405 method_not_allowed with Allow:, never a silent 404",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-method-mismatch", profile:)

    probes = [
      [:get,  "/kiosk/reserve_room", "POST", nil],
      [:post, "/kiosk/my_bookings",  "GET",  {}],
    ].map do |method, path, wanted, body|
      res, doc = raw(a, method, path, body)
      ok = res.code.to_i == 405 && doc["code"] == "method_not_allowed" &&
           res["allow"].to_s.upcase.include?(wanted)
      [ok, "#{method.to_s.upcase} #{path} → #{res.code}/#{doc["code"].inspect} " \
           "Allow=#{res["allow"].inspect} (want 405/method_not_allowed/#{wanted})"]
    end

    Kiosk::Redteam::Verdict.new(
      blocked: probes.all? { |ok, _| ok },
      skipped: false,
      status:  405,
      detail:  probes.all? { |ok, _| ok } ? "" : "a method mismatch is not answered " \
                                                 "405/method_not_allowed with Allow: " \
                                                 "#{probes.map(&:last).join("; ")}",
    )
  end
end

# ── NO AVAILABILITY IN THE PAST, AND NO BOOKING INTO IT ───────────────────────
#
# There must be zero availability for past dates, and no booking into them.
# Unguarded, `reserve_room` with `check_in: "1900-01-01"` answers 200 with a
# real booking and a real quote, and `availability` for those nights lists
# rooms.
#
# BOTH HALVES ARE PROBED, and the second is not redundant. The read side is the
# primary fix — an assistant must never SEE a room it cannot book — but an
# assistant may name a date it never read from an availability response, which
# is exactly how a stay in the past gets sold. So the sale is guarded too,
# from the same {WireArguments.past_stay}, and both are asserted here.
#
# THE CONTROLS ARE WHAT MAKE IT NON-VACUOUS. A handler that refused EVERY date,
# or one that answered `[]` to everything, would satisfy the refusals alone. So
# each probe is paired with the same call at a FUTURE date, which must be
# answered: rooms listed, and a hold minted.
#
# TODAY IS DELIBERATELY NOT PROBED AS A REFUSAL. hoteling's floor is the DAY, in
# the property's clock (Europe/Istanbul), and today is bookable — a same-day
# arrival is an ordinary room-night. Probing "today must be accepted" from a
# runner on an arbitrary clock would be a test of the RUNNER's timezone, not of
# the operator's, so the beat asserts the two ends that are unambiguous from any
# clock: a century ago is refused, a month out is answered.
class PastStay < Kiosk::Redteam::Scenario
  PAST_IN  = "1900-01-01"
  PAST_OUT = "1900-01-04"
  # Its OWN nights, deliberately disjoint from CHECK_IN..CHECK_OUT, so the
  # control HOLD neither consumes nor depends on the inventory the generic
  # scenarios share — the same arrangement {DoubleBookedRoom} makes and for the
  # same reason.
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
    a        = register_principal(client, name: "redteam-paststay-a", profile:)
    found    = FIND_AVAILABLE.call(client, a)
    prop_id  = found[:prop]["property_id"]
    room_id  = found[:room]["room_type_id"]
    failures = []
    statuses = []

    # ── Half 1: the READ side. Zero availability for a past date. ───────────
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

    # ── Half 2: the WRITE side. A past room-night cannot be held. ───────────
    past_hold = client.run(a, name: "reserve_room", property_id: prop_id, room_type_id: room_id,
                                                    check_in: PAST_IN, check_out: PAST_OUT)
    statuses << past_hold.status
    unless refusal?(past_hold)
      failures << "reserve_room(#{PAST_IN}..#{PAST_OUT}) → HTTP #{past_hold.status} " \
                  "code=#{error_code(past_hold).inspect} body=#{JSON.generate(past_hold.body)[0, 160]} " \
                  "(want 400 bad_request; a 200 here is a sold room-night from last century)"
    end

    # CONTROL for half 2 — the same call at a future date must mint a hold, so
    # the refusal above cannot be an unrelated argument or ownership answer.
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

  # The refusal this origin owes for a value outside a verb's domain: spec
  # §9.1's first branch — 400 `bad_request` NAMING what it accepts. The date in
  # the sentence is read in the PROPERTY's locale, which is not necessarily the
  # runner's, so the assertion is "a calendar date is named", never a literal
  # equal to this machine's `Date.today`.
  def refusal?(resp)
    detail = resp.body.is_a?(Hash) ? resp.body["detail"].to_s : ""
    resp.status == 400 && error_code(resp) == "bad_request" &&
      detail.include?("in the past") && detail.match?(/\d{4}-\d{2}-\d{2}/)
  end
end

# ── Scenario list ─────────────────────────────────────────────────────────────
#
# The generic Kiosk::Redteam battery plus hoteling's own beats (3 cashier-check
# + 2 input-shape + 1 date + 1 inventory + the 2 wire-shape beats the 0.4
# cutover made expressible, per the header above). The 3 KYC variants are the
# only expected skips — RegistrationWithoutPow runs, because register PoW is ON.
# NO TOTALS ARE WRITTEN DOWN HERE: the run prints `scenarios.size` and the skip
# count below, and a total written here is a total that rots.

scenarios = [
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,      # C2 — headline
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,      # C3 — re-confirm
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::PrivilegeSelfSelection.new,
  # The CLAIM-ceremony sibling of the line above: PrivilegeSelfSelection covers
  # `/auth/register`, where the role is never client-supplied; this covers the
  # other door — the unauthenticated `device_authorization` request that opens
  # the account-binding ceremony.
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  WrongCurrencyCart.new,                                  # cashier check — currency
  TamperedPriceCart.new,                                  # cashier check — below quote
  InflatedTotalCart.new,                                  # cashier check — total ≠ line sum
  MalformedUuidArg.new,                                   # junk uuid → typed 400, no 500
  HostileArgShapes.new,                                   # boolean/array/object/date shapes → typed 400
  DoubleBookedRoom.new,                                   # one room-night, one booking
  RetiredWire.new,                                        # the 0.3 pair is 404, not a shim
  MethodMismatch.new,                                     # 0.4 — wrong method is 405 + Allow, not 404
  PastStay.new,                                           # no availability in the past, no booking into it
  Kiosk::Redteam::Scenarios::MissingKyc.new,              # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,              # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::ForgedKyc.new,               # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new,  # → BLOCKED (register PoW ON)
]

# ── Expected-applicable assertion ─────────────────────────────────────────────
#
# hoteling has no KYC — these 3 KYC variants are expected to be skipped.
# RegistrationWithoutPow is NOT skipped: register PoW is ON, so it runs and must
# be BLOCKED. If this set changes, a profile key was silently set to nil,
# disabling a gate scenario that should be applicable.
EXPECTED_SKIP_NAMES = %w[
  ExpiredKyc
  ForgedKyc
  MissingKyc
].freeze

# ── Run ───────────────────────────────────────────────────────────────────────

puts "\n── hoteling redteam battery ──"
puts "  base_url:       #{BASE_URL}"
# DERIVE BOTH, NEVER TYPE THEM.  A typed `requires_kyc: false` sitting directly
# under a line that already reads `profile.pow_difficulty` off the object lets
# one flipped constructor argument 940 lines up leave the banner announcing the
# opposite of the battery it introduces.  The ON/OFF gloss is derived for the
# same reason: `1 (register PoW ON)` and `0 (register PoW ON)` are both
# printable, and only one of them is ever true.
#
# These are the values every generic scenario reads to decide whether it is
# applicable — RegistrationWithoutPow skips on 0, the KYC trio skips on false —
# so the banner now says exactly what the run below will do.
puts "  pow_difficulty: #{profile.pow_difficulty} (register PoW #{profile.pow_difficulty.to_i > 0 ? "ON" : "OFF"})"
puts "  requires_kyc:   #{profile.requires_kyc}"
puts "  scenarios:      #{scenarios.size} (#{EXPECTED_SKIP_NAMES.size} expected skips)"
puts ""

runner  = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile:)
results = runner.run(scenarios)

# ── Summary ───────────────────────────────────────────────────────────────────

blocked_results = results.select { |r| !r[:verdict].skipped && r[:verdict].blocked }
skipped_results = results.select { |r| r[:verdict].skipped }
breach_results  = runner.breaches

puts "\n── Summary ──"
blocked_results.each { |r| puts "  BLOCKED  ✓ #{r[:scenario].name}" }
skipped_results.each do |r|
  reason = r[:verdict].detail.delete_prefix("SKIP — ")
  puts "  SKIPPED  — #{r[:scenario].name} (#{reason})"
end
breach_results.each { |r| puts "  BREACH   ✗ #{r[:scenario].name} — #{r[:verdict].detail}" }

puts ""
if breach_results.empty?
  puts "  #{blocked_results.size} BLOCKED, #{skipped_results.size} SKIPPED, 0 BREACH — all attacks blocked."
else
  puts "  #{blocked_results.size} BLOCKED, #{skipped_results.size} SKIPPED, #{breach_results.size} BREACH"
end

# ── Expected-applicable check ─────────────────────────────────────────────────

actual_skip_names = skipped_results.map { |r| r[:scenario].name }.sort
expected_sorted   = EXPECTED_SKIP_NAMES.sort

if actual_skip_names != expected_sorted
  puts ""
  puts "  EXPECTED-APPLICABLE ASSERTION FAILED:"
  puts "    Expected skips: #{expected_sorted.inspect}"
  puts "    Actual skips:   #{actual_skip_names.inspect}"
  puts "  A profile key may have been set to nil, disabling a gate scenario."
  exit 2
end

exit 1 if breach_results.any?
