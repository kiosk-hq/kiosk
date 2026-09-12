# frozen_string_literal: true

# getgrocery redteam battery (P6 corrected surface)
#
# Surface: catalog, delivery_slots, my_orders / create_order, reschedule_delivery
#
# THE PROFILE IS NOT MAPPED OUT HERE. `Profile.new` further down is the single
# copy of every binding — which verb plays each generic role, and the gate
# posture — each stated at the constructor beside the `*_args` lambda that shows
# what the verb actually takes; the run header prints the posture live off the
# object every scenario reads. A map up here would be five hand-copied facts
# that a RENAME turns into a reader believing the battery attacks a verb it no
# longer names. Six of the seven demo redteam suites carry no such map, hoteling
# and skooti included — the only other two that build a Profile at all — and
# they are read from the constructor exactly as this one is.
#
# Every capture runs the ValidatingPaymentProvider cashier check: the cart
# must be EUR, reference the payer's own unsettled order, mirror its items at
# catalog prices, and sum correctly. Three local scenarios attack exactly that,
# and a fourth (MalformedItemsCart) attacks the input shape create_order takes.
#
# THE 0.4 WIRE. A query is `GET /kiosk/<query-name>` with its arguments in the
# query string and an action is `POST /kiosk/<action-name>` with its arguments
# as the JSON body. A success body IS the result (a bare array from a
# non-paginating query, the action's own object from an action, the settlement
# object from `pay`), and an error is an RFC 9457 problem document whose branch
# point is the TOP-LEVEL `code`. Two of the scenarios below are about the shape
# of that wire rather than about this shop — UnregisteredVerbIsOrdinaryRefusal
# and MethodMismatch — and both are here because a path that answers more than
# the ordinary refusal, or serves a write to the wrong method, is an attack
# surface.
#
# THE BEAT LIST. `scenarios = [` further down is the single copy of the
# MEMBERSHIP and `EXPECTED_SKIP_NAMES` beside it is what ASSERTS the
# applicable/skip split, so a silently disabled gate fails the RUN rather than
# merely contradicting a comment. What follows is a restatement of that
# membership for a reader, and it is held to it mechanically in both
# directions: a name here that nothing registers, and a registered beat with
# no line here, are each a red gate rather than a stale comment. That is what
# makes an enumeration worth writing down — the PROFILE above is the opposite
# case, because nothing derives it.
#
# The list is COMPLETE and each must be BLOCKED, except the KYC trio, which
# must SKIP because this shop asks for no attestation:
#
#   CrossTenantRead        — B's my_orders must not include A's orders
#   ForgedUserId           — a forged user_id in create_order is a typed 400:
#                            the principal is not a declared input, and B's own
#                            order stays B's
#   UnpaidGatedAction      — reschedule_delivery without a settled mandate
#   SpentResourceReuse     — a paid order reschedules once; the second attempt
#                            is refused
#   PayForOtherUseSelf     — a mandate paid for one order cannot gate another
#   MandatePrincipalSwap   — B signs a mandate carrying A's identity
#   MandateReplay          — B re-submits A's signed mandate JWS
#   TokenTampering         — an altered JWT (one claim flipped) is a 401
#   PrivilegeSelfSelection — an agent cannot self-assign elevated privilege
#   DeviceGrantRoleSelfSelection — the binding ceremony's unauthenticated
#                            opening request refuses `role`/`scope`, at a
#                            DECLARED value as well as an invented one
#   WrongCurrencyCart      — a usd cart at a EUR operator, refused at capture
#   TamperedPriceCart      — a line price differing from the catalog
#   InflatedTotalCart      — a total above the sum of its lines
#   MalformedItemsCart     — a non-array (or non-object-element) `items` is a
#                            typed 400, never a 500
#   HostileArgShapes       — boolean/array/object/junk on delivery_slot_id,
#                            delivery_date, delivery_address and order_id is a
#                            typed 400 too, never a 500
#   UnregisteredVerbIsOrdinaryRefusal — POST /kiosk/query and POST /kiosk/run
#                            name no registered verb and no route draws them,
#                            so both answer the ordinary 404 any undrawn path
#                            gets, bearer or not; no privileged endpoint hides
#                            behind a generic-sounding word
#   MethodMismatch         — a GET at an action's path draws no route either,
#                            so it is the same plain 404 with no `Allow`, and
#                            the write never runs
#   PastDeliveryDate       — a delivery date in the past is a named 400, never
#                            an ambiguous 200 with an empty list
#   CallerZoneIsNotInferred — the caller's clock is DECLARED and never guessed:
#                            with no `Kiosk-Timezone` the answer is the same
#                            whatever locale, geolocation hint or proxy IP the
#                            request also carries, on an origin that
#                            demonstrably reads the header when it is sent
#   OneRenderingPerRow     — a row is rendered at the delivery address's clock
#                            and once: two callers on clocks 25 hours apart get
#                            byte-identical windows, and neither answer names
#                            the caller's own zone anywhere in its bytes
#   MachineTimestampsIgnoreTheCallerClock — an auth challenge's `exp` is an
#                            instant, not a service time: it does not move with
#                            the caller's declared clock
#   KycBrokerUnwired       — with no KYC broker configured (which is how the
#                            demo task boots this origin, and how a plain
#                            `rails s` does), request_kyc answers 501 with a
#                            hint saying a retry will not help — never a 500
#                            carrying a Ruby exception message
#   RegistrationWithoutPow — register without a valid PoW proof; this origin
#                            gates registration (registration_pow_count = 1)
#
# And the trio that must SKIP:
#
#   MissingKyc             — no attestation surface here to attack
#   ExpiredKyc             — same, with an expired attestation
#   ForgedKyc              — same, with a self-asserted one
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3001 KIOSK_ISSUER=http://127.0.0.1:3001 \
#   bundle exec ruby script/redteam_suite.rb

require "date"
require "json"
require "kiosk/redteam"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

BASE_URL = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")

# ── Profile ───────────────────────────────────────────────────────────────────

profile = Kiosk::Redteam::Profile.new(
  # register PoW is ON (registration_pow_count=1): a positive difficulty makes
  # RegistrationWithoutPow RUN (a missing/bad register proof must be rejected).
  # The Client ignores the magnitude (PoW solving is driven by the server's 402
  # challenges); only "> 0" matters here.
  pow_difficulty: 1,
  requires_kyc:   false,

  # ── declared_roles — DeviceGrantRoleSelfSelection ────────────────────────
  # `Kiosk.configuration.roles` for this origin (config/initializers/kiosk.rb).
  # The claim ceremony's beat must name a role this origin ACTUALLY declares:
  # an invented one is refused even by an implementation that lets a DECLARED
  # role through, so a battery probing only an invented role stays green over a
  # real hole. The scenario also derives one off the wire, so a stale list here
  # weakens the probe rather than emptying it.

  # The currency this operator prices in — WrongCurrencyCart probes with one
  # that is NOT it.
  currency:       "eur",
  declared_roles: %w[customer],
  per_user_query: "my_orders",

  # result_id_key: create_order's response body IS the order object, so the key
  #                is read straight off it — body["order_id"] (0.4: no envelope)
  # row_id_key:    my_orders rows carry an "order_id" field (it matches the
  #                consumer param name so an assistant copies the same key)
  result_id_key: "order_id",
  row_id_key:    "order_id",

  # create_owned: query catalog → pick first in-stock product → create_order
  # (delivery slot + address are REQUIRED — delivery is part of the order).
  # Returns { id:, total_cents:, items: [{sku, qty, price_cents}] } — the items
  # are kept so pay_for can build a cart that MIRRORS the order at catalog
  # prices (the ValidatingPaymentProvider cashier check requires it).
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
      delivery_slot_id: 1,
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

  # forge_args: returns base args for create_order — which needs a delivery slot
  #             and an in-zone address on top of its items (user_id injected by
  #             the ForgedUserId scenario, never declared here)
  forge_action: "create_order",
  forge_args: ->(client, _principal_a, _principal_b) {
    # Query the catalog as B to get a valid sku for create_order; the
    # ForgedUserId scenario adds user_id: A's UUID on top of these args.
    #
    # WHAT THIS BEAT PROVES. `create_order` publishes
    # `additionalProperties: false` and does not declare `user_id` — the
    # principal is not one of its inputs — and the wire validates `input_schema`
    # on every call, so the forged argument is REFUSED (400 bad_request naming
    # it) rather than accepted and silently ignored. The ownership half is
    # proved too: nothing B creates ever appears under A.
    catalog_resp = client.query(_principal_b, name: "catalog")
    catalog = catalog_resp.body.is_a?(Array) ? catalog_resp.body : []
    raise "redteam: catalog empty for forge_args" if catalog.empty?
    product = catalog.first
    {
      items:            [{ sku: product["sku"], qty: 1 }],
      delivery_slot_id: 1,
      delivery_address: "1 Redteam St, Dublin 1",
    }
  },

  # gated_action — gated on ownership + settled payment, and ONE reschedule per
  # order: the second attempt is the C3 spent-resource beat. (The verb is on the
  # line below and is not repeated here.)
  gated_action: "reschedule_delivery",
  gated_args:   ->(owned_ref) {
    {
      order_id:         owned_ref[:id],
      delivery_slot_id: 2,
    }
  },

  # pay_for: build RS256 intent + cart mandates referencing order_id, with
  # item lines MIRRORING the order at catalog prices (cashier check).
  # No card-setup step: this suite runs with KIOSK_TEST_AUTOCARD=1 against
  # stripe-mock, so the adapter auto-provisions a test card at capture and the
  # off_session charge settles. The gates under test are pure Kiosk logic.
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

# ── Local scenarios: the cashier check (ValidatingPaymentProvider) ────────────
# The generic battery proves ownership/payment gates, and its
# WrongCurrencyCart covers the unit of account; these two prove the operator
# counts what lands on the counter — the line prices and the total.

# A tampered per-line price (with total and cap adjusted to stay
# chain-consistent) must be caught by the catalog-mirror check.
class TamperedPriceCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "TamperedPriceCart",
      category:    "payment",
      description: "A cart whose line price differs from the catalog must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-price-a", profile:)
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
    # 403 by name, not the delegated `blocked?` set: a 401 would say the
    # credential was rejected, which means the cashier never priced this cart.
    verdict_from(resp, expect: 403, detail: "below-catalog line price settled (HTTP #{resp.status})")
  end
end

# Correct lines but an inflated total (within the intent cap, payment mirrors
# the cart) must be caught by the sum check.
class InflatedTotalCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "InflatedTotalCart",
      category:    "payment",
      description: "A cart whose total exceeds the sum of its lines must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-total-a", profile:)
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)
    m[:cart] = m[:cart].merge(total_amount_cents: owned[:total_cents].to_i + 100)
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    # 403 by name — see TamperedPriceCart above.
    verdict_from(resp, expect: 403, detail: "total above the order's catalog sum settled (HTTP #{resp.status})")
  end
end

# A cart of the wrong SHAPE is a client mistake and must come back as a typed
# 400, never as a 500. An `items.empty?` guard under a message promising "a
# non-empty array" is an emptiness check wearing a type check's words, and
# `items` is not validated at the wire either (request_validation.rb: "ONLY the
# PoW proof(s) are validated"), so a String, a Hash, or an array of Strings
# reaches `.map` / `it[:sku]` and raises a raw NoMethodError or TypeError that
# executor.rb turns into ActionFailed — a 500 on this demo's headline action,
# the one the onboarding page is modelled on.
#
# Since 0.4 the FIRST of these refusals comes from the schema layer rather than
# from the handler: `input_schema` is validated on every call and `items`
# declares `{type: "array", minItems: 1, items: {…}}`, so a String, an Integer
# or an array of Strings is refused before {WireArguments.items} runs. The
# assertion is unchanged and still worth making — what it pins is that a
# mis-shaped cart is a TYPED 400 an assistant can act on, not which layer
# produced it, and the handler guard stays as the floor for shapes the schema
# admits.
#
# Asserts HTTP 400 AND a top-level `code == "bad_request"` AND no Ruby internals
# in the body: "not 200" would accept exactly the 500s at issue.
class MalformedItemsCart < Kiosk::Redteam::Scenario
  ADDRESS = "1 Redteam St, Dublin 1"
  RUBY_INTERNALS = ["NoMethodError", "TypeError", "undefined method", "no implicit conversion"].freeze

  # Each is a shape an assistant can plausibly send: the whole cart as one
  # object, a bare list of skus, a stringified cart, a count.
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
    a        = register_principal(client, name: "redteam-items-a", profile:)
    failures = []
    statuses = []

    BAD_ITEMS.each do |label, items|
      args = { delivery_slot_id: 1, delivery_address: ADDRESS }
      args[:items] = items unless items.nil?
      resp = client.run(a, name: "create_order", **args)
      statuses << resp.status
      code = resp.body.is_a?(Hash) ? resp.body["code"] : nil
      # THE SCAN IS TOLD WHAT THIS PROBE SENT. {WireArguments.items}
      # names the element it rejected — `each item must be a {sku, qty} object
      # — got String ("sourdough-bread")` — so the bytes scanned for
      # RUBY_INTERNALS are partly the probe's own, and a cart whose sku spelled
      # `TypeError` would be reported as a BREACH on its own echo, under a
      # runner whose prose says a BREACH means "fix the app, not the scenario".
      scan = Kiosk::Redteam::LeakScan.scan(resp.body, RUBY_INTERNALS, supplied: args)
      next if resp.status == 400 && code == "bad_request" && !scan.leak?

      failures << "items #{label} → HTTP #{resp.status} code=#{code.inspect}" \
                  "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
    end

    # CONTROL — a well-formed cart must still place an order. Without it every
    # probe above would pass against a handler that rejected all input.
    catalog_body = client.query(a, name: "catalog").body
    catalog = catalog_body.is_a?(Array) ? catalog_body : []
    control = client.run(a, name: "create_order",
                            items: [{ sku: catalog.first["sku"], qty: 1 }],
                            delivery_slot_id: 1, delivery_address: ADDRESS)
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

# THE STANDING HOSTILE-SHAPE BEAT.
#
# Postgres does free shape-checking on wire arguments and ActiveRecord does not,
# and getgrocery has both classes of the consequence. `order_id` interpolated
# into a `::uuid` cast is class one, held by {Kiosk::UuidCheck}. `delivery_slot_id` /
# `qty` read with a bare `.to_i` — which `true`, `false`, an Array and an object
# all answer with NoMethodError — is class two: a `500 action_failed` for an
# argument the published `input_schema` already declares an integer, held by
# reading through `.to_s` first. This is the standing beat that re-sends those
# hostile shapes on every run. {MalformedItemsCart} stands for the `items`
# CONTAINER — a String, a bare Hash, an array of strings, `[]`, absent; this one
# takes the scalar arguments it does not, AND the `qty` INSIDE a well-formed
# element, which otherwise falls between the two beats: `qty` is half of class
# two above and `MalformedItemsCart` never varies an element's fields.
#
# WHAT IS PROBED, NAMED RATHER THAN CLAIMED. create_order: `items[].qty`,
# `delivery_slot_id`, `delivery_date`, `delivery_address`. reschedule_delivery:
# `order_id`. An argument not on that list is not covered here — extend the
# list, never widen the sentence.
#
# WHICH LAYER ANSWERS WHAT, measured rather than assumed. `delivery_slot_id`
# declares `type: "integer", minimum: 1, maximum: 6` and `order_id` declares
# `format: "uuid"`, so 0.4's `input_schema` validation refuses those shapes
# BEFORE the handler — for them this beat pins the CONTRACT (typed 400, no 5xx,
# no wrong answer served as 200) across both layers and goes red if either
# stops holding, e.g. if a descriptor widened the type or dropped
# `additionalProperties: false`.
#
# `delivery_address` IS DIFFERENT, and it is why this beat is not merely a
# schema test: it is declared a bare `type: "string"`, because its domain is not
# expressible in JSON Schema — the served zone is a list of Dublin districts
# an operator edits. Every string reaches getgrocery's OWN guard, so an
# out-of-zone address is refused by {WireArguments.served_district} and nothing
# but that guard stands behind it.
#
# `delivery_date` declares `format: "date"`, so the wire refuses every spelling
# but `YYYY-MM-DD` before the handler runs. Two things it still cannot say are
# {WireArguments.delivery_date}'s: that a well-shaped value names a real DAY
# (`2026-02-30` does not), and that the day has not already gone — the delivery
# horizon rolls forward every midnight, which no declaration can track.
class HostileArgShapes < Kiosk::Redteam::Scenario
  ADDRESS = "2 Redteam Row, Dublin 2"

  # An error body must never carry the runtime's or the database's own
  # vocabulary: that is the same property {MalformedItemsCart} asserts, and
  # these probes are the ones most likely to reach a cast.
  LEAKS = ["NoMethodError", "TypeError", "undefined method", "no implicit conversion",
           "::uuid", "PG::", "22P02", "invalid input syntax", "ActiveRecord::"].freeze

  # The five families the row names.
  SHAPES = [true, false, [], {}, [1], { "a" => 1 }, "abc", 1.5].freeze

  def initialize
    super(
      name:        "HostileArgShapes",
      category:    "input",
      description: "Boolean/array/object/junk values on items[].qty, delivery_slot_id, delivery_date, delivery_address and order_id are a typed 400 — never a 500",
    )
  end

  def call(client, profile)
    a         = register_principal(client, name: "redteam-shapes-a", profile:)
    @failures = []
    catalog   = client.query(a, name: "catalog").body
    raise "redteam(getgrocery): empty catalog" unless catalog.is_a?(Array) && catalog.any?

    good_items = [{ sku: catalog.first["sku"], qty: 1 }]

    # ── schema-declared integers and uuids ──────────────────────────────────
    #
    # `delivery_slot_id`: BOTH LAYERS REFUSE ALL EIGHT SHAPES BELOW, and the
    # second layer is what makes that worth asserting — the same trap as
    # `qty`'s below, one argument over. A guard reading `raw.to_s.to_i` turns
    # `"1.5"` into 1, which lands INSIDE the declared 1..6, so `1.5` is the one
    # shape the schema alone refuses and, with nothing in front of it, the
    # handler would book a fractional slot as slot 1. It goes through the same
    # {WireArguments.whole_number} `qty` uses, so `2.0` is still slot 2
    # (json_schemer accepts it) and `1.5` is a 400 from either layer. The
    # non-vacuity proof: drop `delivery_slot_id`'s declared type from both
    # verbs' `input_schema` and these stay 400.
    SHAPES.each do |v|
      refused "create_order delivery_slot_id=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: v, delivery_address: ADDRESS),
              supplied: v
      refused "reschedule_delivery order_id=#{v.inspect}",
              client.run(a, name: "reschedule_delivery", order_id: v, delivery_slot_id: 1),
              supplied: v
    end
    # Out of the declared 1..6 range — the same refusal, from the schema's
    # `minimum`/`maximum` rather than its `type`.
    [0, -1, 7, 999].each do |v|
      refused "create_order delivery_slot_id=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: v, delivery_address: ADDRESS),
              supplied: v
    end

    # ── `qty`, INSIDE a well-formed items element ───────────────────────────
    #
    # The container is correct in every call here — one element, a real sku —
    # so the ONLY thing wrong is the element's own `qty`, which is class two of
    # the shape problem above: a bare `.to_i` guard, and `true`/`false`/`[]`/
    # `{}` have none, so each is a `500 action_failed` for a value
    # `input_schema` already declares `{type: "integer", minimum: 1}`.
    #
    # BOTH LAYERS REFUSE ALL TEN VALUES BELOW, and the second layer is easy to
    # lose: a guard reading `(item[:qty] || 1).to_s.to_i` agrees with the schema
    # on eight of them but lets `false` and `1.5` BOTH out as a legal quantity 1
    # — `||` reads `false` as absent, and `"1.5".to_i` is 1 — leaving the schema
    # as the only refusal for those two. `wire_arguments.rb` mirrors the schema's
    # own `integer` instead (whole numbers, `2.0` included, because json_schemer
    # accepts that — measured), so a 400 here is two refusals rather than one.
    # The non-vacuity proof is a mutation: drop `qty`'s declared type from
    # `input_schema` and these stay 400 instead of booking `false` and `1.5` as
    # one unit.
    sku = catalog.first["sku"]
    (SHAPES + [0, -1]).each do |v|
      refused "create_order items[0].qty=#{v.inspect}",
              client.run(a, name: "create_order", items: [{ sku: sku, qty: v }],
                            delivery_slot_id: 1, delivery_address: ADDRESS),
              supplied: { sku: sku, qty: v }
    end

    # ── MAGNITUDE, the axis every probe above misses ────────────────────────
    #
    # Everything above varies `qty`'s TYPE, and `[0, -1]` sit just under the
    # declared `minimum: 1`. An integer LARGE enough to matter is a separate
    # axis, and a beat can vary every shape there is without ever reaching it —
    # which is how a `500 action_failed` for a body the published descriptor
    # calls VALID hides behind a full set of type probes.
    #
    # TWO probes, because there are two bounded columns behind one argument and
    # they give way at different widths. Both numbers are DERIVED from the
    # catalogue row this run actually got, so a reseed at other prices cannot
    # quietly make either vacuous:
    #
    #   · UNPRICEABLE CART — `qty` is a legal `order_items.qty` (int4) and the
    #     cart still cannot be TOTALLED: `price_cents * qty` passes
    #     `orders.total_cents`, also int4. MEASURED on a booted origin with no
    #     total guard in front, `qty: 30_000_000` of the 89-cent `milk-0.5l` →
    #     `ActiveModel::RangeError: 2670000000 is out of range …` out of
    #     `Order.insert!`, served as **HTTP 500 `action_failed`**. The refusal
    #     it must be instead comes from {WireArguments.priceable_total}, which
    #     is reached only once the prices are resolved — no schema can express
    #     a bound on a SUM of other rows' values.
    #   · UNSTORABLE QUANTITY — `qty` itself past int4, which IS expressible
    #     per-property and so is refused by the descriptor's own `maximum`
    #     before the handler runs at all.
    #
    # The non-vacuity proof is a mutation, one bound at a time:
    # drop `maximum` from `qty` in `input_schema` and the second probe reaches
    # the handler; delete the `priceable_total` call from
    # {CreateOrderOperation} and the first goes back to 500.
    price = catalog.first["price_cents"].to_i
    raise "redteam(getgrocery): catalogue row has no price_cents" unless price.positive?

    max_int4 = 2_147_483_647
    { "unpriceable cart"     => (max_int4 / price) + 1,
      "unstorable qty"       => max_int4 + 1 }.each do |why, v|
      refused "create_order items[0].qty=#{v} (#{why})",
              client.run(a, name: "create_order", items: [{ sku: sku, qty: v }],
                            delivery_slot_id: 1, delivery_address: ADDRESS),
              supplied: { sku: sku, qty: v }
    end

    # ── the two bare strings, where getgrocery's OWN guards are the only
    # thing standing (see the header) ───────────────────────────────────────
    # A date on this wire is `YYYY-MM-DD` and nothing else, so the spellings a
    # loose reader would take are probed here beside the junk: the one-element
    # array `"[2026-09-01]"`, the basic-ISO `"20260101"`, and `"09/01/2026"`,
    # which is day-first to some senders and month-first to others — the value
    # the rule was decided on, and the one an accepting origin answers without
    # telling anybody which reading it took.
    ["nope", "2026-13-45", "0000-01-01", "true",
     "[2026-09-01]", "20260101", "09/01/2026"].each do |v|
      refused "create_order delivery_date=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items, delivery_slot_id: 1,
                            delivery_address: ADDRESS, delivery_date: v),
              supplied: v
    end
    ["", "   ", "1 Main St, Cork", "Dublin 99", "somewhere"].each do |v|
      refused "create_order delivery_address=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: 1, delivery_address: v),
              supplied: v
    end

    # ── CONTROL ─────────────────────────────────────────────────────────────
    #
    # Without it every assertion above could pass vacuously on an origin that
    # refuses EVERYTHING. A well-formed order must still be placed.
    control = client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: 1, delivery_address: ADDRESS)
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

  # `supplied:` is what this probe put on the wire, and it is what stops the
  # leak assertion being decided by the attacker. getgrocery names the value it
  # got — `invalid delivery_date: nope`, `qty must be a whole number >= 1 —
  # got …` — so the bytes scanned for LEAKS are partly the probe's own, and a
  # `delivery_address` spelling `PG::` would otherwise be reported as a BREACH
  # on its own echo, under a runner whose prose says a BREACH means "fix the
  # app, not the scenario". The default is nil, which discounts nothing:
  # forgetting to declare risks a FALSE BREACH, never a missed leak.
  def refused(label, resp, supplied: nil)
    doc  = resp.body.is_a?(Hash) ? resp.body : {}
    scan = Kiosk::Redteam::LeakScan.scan(resp.body, LEAKS, supplied: supplied)
    return if resp.status == 400 && doc["code"] == "bad_request" && !scan.leak?

    @failures << "#{label} → HTTP #{resp.status} code=#{doc["code"].inspect}" \
                 "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
  end
end

# ── The wire's own shape: two scenarios about paths, not about this shop ─────
#
# Both dial raw paths, so they use Net::HTTP directly rather than the Client's
# verb helpers — the Client speaks REGISTERED verbs, and what is under test here
# is what happens at a path that is not one.

# A path that answers more than the ordinary refusal is a second conformance
# surface, and a second conformance surface is somewhere an attacker looks for
# the gate the first one has. `POST /kiosk/query` and `POST /kiosk/run` name no
# verb this shop registers, so no line in config/routes/kiosk.rb draws them and
# nothing under the mount matches: they answer the ordinary 404 any undrawn path
# gets — no privileged endpoint hiding behind a generic-sounding word, and
# nothing naming a replacement an attacker could probe. Those two names are
# what a caller hunting for a multiplexed endpoint tries first, which is why
# the beat dials them rather than a nonsense word.
#
# BOTH CALLERS ARE PROBED, and the point is that they answer ALIKE. A routing
# miss is decided before any credential is read, so a bearer buys nothing here
# and neither caller gets a problem document to read anything out of.
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
    a = register_principal(client, name: "redteam-unregistered-a", profile:)

    results = UNREGISTERED.flat_map do |name|
      [[a.token, ""], [nil, " (anon)"]].map do |token, tag|
        uri     = URI("#{BASE_URL}/kiosk/#{name}")
        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{token}" if token
        req = Net::HTTP::Post.new(uri, headers)
        req.body = JSON.generate(name: "catalog")
        res  = Net::HTTP.new(uri.host, uri.port).request(req)
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

# A GET at an ACTION's path draws no route here — this shop draws `POST
# /kiosk/create_order` and nothing else at that path — so it is the same
# ordinary 404 any undrawn path gets. What the beat is FOR is the security half:
# the wrong method must never reach the action, and must never carry an `Allow`
# an attacker could read as a map of the surface. The catalogue at
# `GET /kiosk/schema` is where a caller learns which method a verb takes.
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
    a   = register_principal(client, name: "redteam-method-a", profile:)
    uri = URI("#{BASE_URL}/kiosk/create_order")
    res = Net::HTTP.new(uri.host, uri.port)
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

# A `date` in the PAST on `delivery_slots` must be a typed 400 naming the
# earliest bookable day — not `200 []` (spec §9.1).
#
# WHY THE ADVERSARIAL BATTERY OWNS THIS. The empty list this replaces was not a
# missing check, it was an AMBIGUOUS ANSWER: `DeliverySlots.bookable_ids`
# rejects every window whose start has passed, and every window of a past day
# has, so a date thirty days back returned byte-identical bytes to TODAY once
# the last window has begun. One of those two is worth retrying tomorrow and
# the other never will be, and an assistant reading `[]` could not tell which
# it had. Two answers that cannot be told apart is the shape this battery
# exists to catch.
#
# The CONTROL is what makes the beat non-vacuous: a FUTURE date at the same
# in-zone address must still be ANSWERED, or a handler that refused every date
# would pass.
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
    a = register_principal(client, name: "redteam-pastdate-a", profile:)

    past   = (Date.today - 30).iso8601
    future = (Date.today + 7).iso8601

    bad = client.query(a, name: "delivery_slots", date: past, delivery_address: ADDRESS)
    ctl = client.query(a, name: "delivery_slots", date: future, delivery_address: ADDRESS)

    # The refusal must NAME the earliest bookable day, and that day is read in
    # the OPERATOR's locale (Europe/Dublin) — which is not necessarily the
    # runner's. So the assertion is "a calendar date is named", not a literal
    # equal to this machine's `Date.today`: pinning the runner's clock into the
    # expectation would make the beat fail across a timezone boundary for a
    # reason that has nothing to do with the behaviour under test.
    detail  = bad.body.is_a?(Hash) ? bad.body["detail"].to_s : ""
    named   = detail.include?("in the past") && detail.match?(/\d{4}-\d{2}-\d{2}/)
    refused = bad.status == 400 && error_code(bad) == "bad_request" && named
    control = ctl.status == 200 && ctl.body.is_a?(Array) && ctl.body.any?

    # ── THE WRITE HALF ──────────────────────────────────────────────────────
    # The read side is the primary guarantee — an assistant must never SEE a
    # window it cannot book — but an assistant may name a date it never read
    # from a `delivery_slots` response, so the ORDER has to refuse it too. That
    # is the belt to this beat's braces: {WireArguments.delivery_date} refuses
    # `date < Date.today`. `getgrocery_flow.rb` pins the past-WINDOW guard, but
    # only CONDITIONALLY — its probe is a no-op before 08:00 Dublin. This half
    # is unconditional and is about the past DAY.
    sku      = (client.query(a, name: "catalog").body.then { |b| b.is_a?(Array) ? b : [] }).first&.dig("sku")
    order    = client.run(a, name: "create_order", items: [{ sku: sku, qty: 1 }],
                             delivery_slot_id: 1, delivery_address: ADDRESS, delivery_date: past)
    o_detail = order.body.is_a?(Hash) ? order.body["detail"].to_s : ""
    order_refused = order.status == 400 && error_code(order) == "bad_request" &&
                    o_detail.include?("in the past") && o_detail.match?(/\d{4}-\d{2}-\d{2}/)

    # CONTROL for the write half — the SAME cart at a future date must place an
    # order, so the refusal above cannot be an unrelated cart or address answer.
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

# ── THE THREE TIME-ZONE RULES NOTHING PROBED (spec §3.8.5, §3.8.9, §3.8.11) ──
#
# A caller's clock is a declared header and an answer's clock is a property of
# the serviced resource. Three of the rules that follow from that are ABSENCES —
# things an operator must not do — and an absence is true of this shop because
# of how it happens to be built, with nothing that would go red if it were built
# the other way. These three beats are the probes for them, and they share one
# shape: SEND THE SAME REQUEST ON TWO CLOCKS TWENTY-FIVE HOURS APART AND SEE
# WHAT MOVES.
#
# Two zones, chosen for two reasons. Neither observes DST, so a local date is a
# fixed offset from UTC and this script needs no tzinfo — it runs outside a
# Rails boot. And they are 25 hours apart, which is more than a day, so their
# calendar dates DIFFER at every instant there is; a probe built on them has no
# time-of-day branch and no window where it proves nothing.
CLOCK_EAST = "Pacific/Kiritimati" # UTC+14, no DST
CLOCK_WEST = "Pacific/Niue"       # UTC-11, no DST

# READ THE DAY FROM AN INSTANT SLIGHTLY AHEAD OF NOW. The control below needs a
# day the WEST clock is still inside when the LAST of its requests lands, and
# without the lead there is one second a day — the instant Niue's midnight
# passes — where the day is computed as current and is over by the time it is
# asked about. Five minutes is far longer than the whole battery.
CLOCK_PROBE_LEAD = 300

# The local calendar day in a zone whose offset never changes, as `YYYY-MM-DD`.
def clock_probe_day(offset_hours)
  (Time.now.utc + CLOCK_PROBE_LEAD + (offset_hours * 3600)).to_date.iso8601
end

# ── CallerZoneIsNotInferred — §3.8.5's MUST NOT ──────────────────────────────
#
# «It MUST NOT source the caller's zone from the token, `Accept-Language`, IP
# geolocation or the TCP peer.» That is an ABSENCE, and an absence is what this
# workspace has learned to distrust: the fleet obeys it because the engine reads
# ONE env key and no demo consults a second source, which is a fact about how
# this code happens to be written rather than anything a gate could catch
# changing.
#
# SO THE PROBE IS A DIFFERENTIAL, not an inspection. One `delivery_slots` call
# is repeated three times with the SAME arguments and NO `Kiosk-Timezone`:
# once bare, once carrying a Kiribati locale with Kiribati geolocation hints,
# once carrying Niue's. The two baits point at clocks a day apart on either side
# of this shop's own, so an operator that inferred a zone from ANY of those
# headers would answer one of them differently from the other — and both are
# asserted byte-identical to the bare answer.
#
# WHAT MAKES IT NON-VACUOUS is the control, and it runs FIRST: on this very
# verb, an unreadable `Kiosk-Timezone` is a 400 naming the header and a
# well-formed one is answered. So the origin under test demonstrably READS the
# declared clock, and "the baits changed nothing" cannot be the answer of an
# origin that reads no clock at all.
#
# WHAT THE CONTROL DOES NOT ASSERT, because it currently cannot: that a declared
# zone MOVES this verb's answer. That needs two zones more than a calendar day
# apart — anything closer has a time-of-day branch where their dates agree and
# the probe proves nothing — and driving this verb across that span makes it
# answer a 500 rather than the typed refusal §9.1 requires. The defect is
# recorded, and until it is repaired the stronger control would be asserting
# against a known fault instead of against the rule.
#
# WHAT THE PROBE DOES NOT REACH, said out loud rather than left to be assumed:
# the TCP PEER, which a client cannot forge from the outside (`X-Forwarded-For`
# and its proxy siblings are the closest a request can come and are what is sent
# here), and the TOKEN, because nothing in this engine's claim set carries a
# zone, so there is no value for an operator to read off one. Those two halves
# remain construction.
class CallerZoneIsNotInferred < Kiosk::Redteam::Scenario
  ADDRESS = "1 Redteam St, Dublin 1"

  # Every source §3.8.5 forbids, in the spellings a request can actually carry:
  # the locale a country maps to, and the three header shapes a reverse proxy
  # writes a geolocated address into.
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

  # A shape the wire cannot read. It is refused BY NAME rather than fallen back
  # on, which is what makes it usable as a control: the refusal names the header
  # and so can only have come from reading it.
  UNREADABLE = "+03:00"

  def call(client, profile)
    a   = register_principal(client, name: "redteam-inferzone-a", profile:)
    day = clock_probe_day(-11)

    ask = lambda do |headers|
      client.query(a, name: "delivery_slots", date: day, delivery_address: ADDRESS, headers: headers)
    end

    # THE CONTROL, FIRST — this origin reads the declared clock.
    declared = ask.call("Kiosk-Timezone" => CLOCK_WEST)
    garbled  = ask.call("Kiosk-Timezone" => UNREADABLE)
    detail   = garbled.body.is_a?(Hash) ? garbled.body["detail"].to_s : ""
    control  = declared.status == 200 && declared.body.is_a?(Array) && declared.body.any? &&
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
                 "#{UNREADABLE} → #{garbled.status}/#{error_code(garbled).inspect} " \
                 "detail=#{detail[0, 80].inspect} (want 200 with rows, and a 400 bad_request " \
                 "naming the header); bare → #{bare.status}, Kiribati-baited → " \
                 "#{baited_e.status} (same=#{unmoved_e}), Niue-baited → #{baited_w.status} " \
                 "(same=#{unmoved_w}) " \
                 "(want both baits byte-identical to bare — a declared clock, never an inferred one)",
    )
  end
end

# ── OneRenderingPerRow — §3.8.9's second sentence ────────────────────────────
#
# «An operator publishes ONE rendering per row and not two — a second wall clock
# in the caller's zone is a field pair that can disagree.» The first sentence of
# that rule is asserted everywhere (every time-bearing row carries `timezone`,
# and `demo:schema` fails a row without one); the second was an absence — no row
# publishes a second wall clock, and nothing looked.
#
# THE PROBE READS THE SAME WINDOWS ON TWO CLOCKS. `delivery_slots` is called with
# no `date`, so both calls ask for the soonest windows this shop has and the
# ONLY difference between them is the caller's declared zone. Two things are
# then asserted, and the second is the one the rule is actually about:
#
#   the shared windows are BYTE-IDENTICAL — a second rendering in the caller's
#   zone would move with it;
#
#   and neither answer names the caller's zone ANYWHERE in its bytes — which
#   catches a second rendering that happens not to differ today, and catches it
#   in a field this beat never had to know the name of.
#
# The comparison is per shared `delivery_slot_id` rather than array-to-array,
# because a window can begin between the two calls and drop out of the second
# answer; that is this shop's own clock advancing, not the caller's zone moving
# anything. The shared set being non-empty is asserted, so the loop cannot pass
# by comparing nothing.
#
# NON-VACUITY: every row must carry a `timezone` whose name is NEITHER caller
# zone and whose value appears in the row's own `label`. So the answer really is
# publishing a wall clock and naming its zone — it is simply never the caller's.
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
    a = register_principal(client, name: "redteam-onerender-a", profile:)

    ask = lambda do |zone|
      client.query(a, name: "delivery_slots", delivery_address: ADDRESS,
                      headers: { "Kiosk-Timezone" => zone })
    end

    west = ask.call(CLOCK_WEST)
    east = ask.call(CLOCK_EAST)
    answered = [west, east].all? { |r| r.status == 200 && r.body.is_a?(Array) && r.body.any? }

    rows_w = answered ? west.body.to_h { |r| [r["delivery_slot_id"], r] } : {}
    rows_e = answered ? east.body.to_h { |r| [r["delivery_slot_id"], r] } : {}
    shared = rows_w.keys & rows_e.keys
    agree  = shared.any? &&
             shared.all? { |id| RENDERING.all? { |f| rows_w[id][f] == rows_e[id][f] } }

    # The caller's zone must not appear in EITHER answer, in any field.
    bytes    = [west, east].map { |r| JSON.generate(r.body) }
    no_caller_zone = bytes.none? { |b| b.include?(CLOCK_WEST) || b.include?(CLOCK_EAST) }

    # …and the answers DO publish a wall clock and DO name its zone, or the
    # clause above would be true of a row that renders nothing at all.
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

# ── MachineTimestampsIgnoreTheCallerClock — §3.8.11 ──────────────────────────
#
# «Machine timestamps are not service times and are unaffected.» An `exp` is an
# INSTANT — a moment a credential stops working — and no clock anybody declares
# changes when that moment is. Nothing here renders one on a caller's clock, and
# until this beat nothing said so.
#
# THE PROBE IS THE SAME DIFFERENTIAL AT A DIFFERENT ENDPOINT. Two auth
# challenges, seconds apart, on clocks 25 hours apart: their `exp` values must
# be within a minute of each other. The number that separates the two answers is
# not close — a value rendered on the caller's clock would be 90,000 seconds
# away, and a run cannot take 90,000 seconds — so the assertion has no tuning in
# it.
#
# NON-VACUITY: both `exp` values must be integers in the FUTURE. A field that
# has gone missing, or gone to zero on both sides, would otherwise satisfy
# "these two agree" perfectly.
#
# THIS COVERS ONE MACHINE TIMESTAMP, the auth challenge's, and it is the engine's
# rather than this shop's — which is why it lives beside the two beats above
# instead of in every suite. A bearer's own `iat`/`exp`, skooti's unlock-token
# `exp` and tudu's `expires_in` are not probed here.
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
    wire = Kiosk::Redteam::Wire.new(base_url: BASE_URL)
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


# THE KYC BROKER IS A SECOND SERVICE AND THIS ORIGIN IS BOOTED WITHOUT IT — which
# is why this battery is where the beat belongs rather than the age-gate flow.
# `demo:agecheck` boots the broker AND sets the intake secret, so no gate in this
# repository had ever called `request_kyc` in the configuration a plain
# `bin/rails s` produces: the one a live demo run uses.
#
# WITHOUT THE TYPED REFUSAL that configuration answers HTTP 500,
# `code: "action_failed"`, `detail: "Action \"request_kyc\" raised RuntimeError: KYC
# broker intake secret is not configured …"` — a Ruby class name on the wire, from
# a NO-ARGUMENT verb an assistant can call first, with no way to tell "this
# operator does not do KYC" from "something crashed".
#
# What is asserted is the SHAPE of the refusal and not merely its status: an
# assistant branches on the flat `code`, so a 501 that carried `action_failed`
# would be as useless as the 500 was.
#
# AND THE DETAIL IS COMPARED WHOLE, not scanned for bad words, because scanning
# was tried here and MEASURED INSUFFICIENT. This beat first carried a blocklist —
# no Ruby class name, no URL — and a planted `"…: #{error.message}"` splice back
# into the refusal sailed through it: the client's own diagnostic names an
# environment variable, not a class, so nothing on the list matched and a beat
# written to catch exactly that shape reported BLOCKED. The sentence is a
# deliberate constant — the same one the engine's KycVerifier answers for the
# submit half of this module — so the honest assertion is equality, and any
# splice at all fails it. The blocklist stays as the second arm because it names
# what must never appear whatever the sentence becomes.
class KycBrokerUnwired < Kiosk::Redteam::Scenario
  # The one sentence this refusal may carry, byte for byte.
  DETAIL = "this operator does not serve the KYC module"

  # The Ruby that must not reach an agent whatever the sentence says. `Errno::`
  # and `RuntimeError` are the two classes this path actually raised; `raised `
  # is the Executor's own wrapper, which is the tell that nothing rescued; a URL
  # is the operator's own broker host, which the refused-connection message
  # carried.
  LEAKS = [/RuntimeError/, /Errno::/, /raised /, %r{https?://}].freeze

  def initialize
    super(
      name:        "KycBrokerUnwired",
      category:    "surface",
      description: "With no KYC broker configured, request_kyc refuses with a typed " \
                   "module_not_served — never a 500 carrying a Ruby exception",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-brokerless-a", profile:)

    res    = client.run(a, name: "request_kyc")
    body   = res.body.is_a?(Hash) ? res.body : {}
    detail = body["detail"].to_s

    typed   = res.status == 501 && error_code(res) == "module_not_served"
    said    = detail == DETAIL
    clean   = LEAKS.none? { |leak| detail.match?(leak) }
    # A refusal with nothing to do next is half an answer: the whole point of
    # this code is that an assistant should stop asking and carry on.
    advises = body["hint"].to_s.match?(/retry|retrying|again/i)

    ok = typed && said && clean && advises
    Kiosk::Redteam::Verdict.new(
      blocked: ok,
      skipped: false,
      status:  res.status,
      detail:  ok ? "" :
                 "request_kyc with no broker configured → #{res.status}/" \
                 "#{error_code(res).inspect} detail=#{detail[0, 160].inspect} " \
                 "hint=#{body["hint"].to_s[0, 120].inspect} " \
                 "(want 501/\"module_not_served\", detail EXACTLY #{DETAIL.inspect} with no " \
                 "Ruby class or URL in it, and a hint that says retrying will not help)",
    )
  end
end

# ── Scenarios ─────────────────────────────────────────────────────────────────

scenarios = [
  # Applicable — must be BLOCKED
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::PrivilegeSelfSelection.new,
  # The CLAIM-ceremony sibling of the line above: PrivilegeSelfSelection covers
  # `/auth/register`, where the role is never client-supplied; this covers the
  # other door — the unauthenticated `device_authorization` request that opens
  # the account-binding ceremony.
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  Kiosk::Redteam::Scenarios::WrongCurrencyCart.new,
  TamperedPriceCart.new,
  InflatedTotalCart.new,
  MalformedItemsCart.new,   # a mis-shaped `items` is a typed 400, never a 500
  HostileArgShapes.new,     # boolean/array/object/junk shapes on the other args → typed 400
  UnregisteredVerbIsOrdinaryRefusal.new, # a path naming no verb → the ordinary refusal
  MethodMismatch.new,       # a GET at an action draws no route → a plain 404, no write
  PastDeliveryDate.new,     # a past date is a named 400 on the read AND the write side
  # The three §3.8 time-zone rules that were held by construction until they
  # were probed: a clock is DECLARED and never inferred, a row is rendered
  # once, and a machine timestamp is not a service time.
  CallerZoneIsNotInferred.new,
  OneRenderingPerRow.new,
  MachineTimestampsIgnoreTheCallerClock.new,
  KycBrokerUnwired.new,     # no broker configured is a typed 501, never a Ruby exception in a 500
  # register PoW is ON — a missing/bad register proof must be rejected (runs
  # because pow_difficulty > 0).
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new,
  # Not applicable — must SKIP (no KYC)
  Kiosk::Redteam::Scenarios::MissingKyc.new,
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,
  Kiosk::Redteam::Scenarios::ForgedKyc.new,
]

# ── Expected-applicable assertion ─────────────────────────────────────────────
EXPECTED_SKIP_NAMES = %w[
  ExpiredKyc
  ForgedKyc
  MissingKyc
].freeze

# ── Run ───────────────────────────────────────────────────────────────────────

puts "\n── getgrocery redteam battery ──"
puts "  base_url:       #{BASE_URL}"
# DERIVE BOTH, NEVER TYPE THEM.  A typed `requires_kyc: false` sitting directly
# under a line that already reads `profile.pow_difficulty` off the object lets
# one flipped constructor argument 660 lines up leave the banner announcing the
# opposite of the battery it introduces.  The ON/OFF gloss is derived for the
# same reason: `1 (register PoW ON)` and `0 (register PoW ON)` are both
# printable, and only one of them is ever true.
#
# These are the values every generic scenario reads to decide whether it is
# applicable — RegistrationWithoutPow skips on 0, the KYC trio skips on false —
# so the banner now says exactly what the run below will do.
puts "  pow_difficulty: #{profile.pow_difficulty} (register PoW #{profile.pow_difficulty.to_i > 0 ? "ON" : "OFF"})"
puts "  requires_kyc:   #{profile.requires_kyc}"
puts ""

runner  = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile:)
results = runner.run(scenarios)

# ── Summary ───────────────────────────────────────────────────────────────────
#
# The gem prints it and the gem answers the exit status: 0 only when at least
# one attack ran and every attack that ran was blocked, 1 on a breach or on a
# battery that proved nothing, 2 when the skips are not the ones named above —
# a profile key that has silently gone nil disables a gate scenario, and that
# must not read as a clean run.
battery = Kiosk::Redteam::Battery.new
battery.absorb(results)
exit battery.report!(expected_skips: EXPECTED_SKIP_NAMES)
