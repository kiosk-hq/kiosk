# frozen_string_literal: true

# hoteling redteam battery
#
# Exercises the hoteling chain: no PoW → no KYC → reserve_room → pay →
# confirm_booking (2-gate: ownership / payment). Headline scenarios:
#   C2  PayForOtherUseSelf  — B pays for A's booking, B tries confirm_booking
#   C3  SpentResourceReuse  — re-confirm an already-confirmed booking
#
# Three local cashier-check beats attack ValidatingBookingProvider (the
# monetary check run at capture, before StubPsp settles):
#   WrongCurrencyCart  — pay own booking in usd → 403
#   TamperedPriceCart  — pay below the operator's quoted booking price → 403
#   InflatedTotalCart  — cart total ≠ sum of its line items → 403
# Plus one input-shape beat:
#   MalformedUuidArg   — a junk booking_id, as an arg AND inside a signed cart,
#                        is a typed 400 with no SQL internals — never a 500
#
# KYC scenarios are SKIPPED (hoteling has no KYC). RegistrationWithoutPow RUNS:
# register PoW is ON (registration_pow_count=1), so a missing/bad register proof
# must be rejected.
#
# Usage (from kiosk-demo-hoteling/):
#   SERVER_URL=http://127.0.0.1:3004 KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby script/redteam_suite.rb
#
# Exits non-zero if any applicable scenario reports a BREACH or if the
# expected skip set does not match (catches profile typos that disable gates).

require "kiosk/redteam"
require "jwt"
require "securerandom"
require "date"

BASE_URL = ENV.fetch("SERVER_URL", "http://127.0.0.1:3004")
ISSUER   = ENV.fetch("KIOSK_ISSUER", BASE_URL)

# Dates far enough in the future to avoid conflicts with existing data.
# Each redteam run starts with a clean DB (demo:setup), so these are stable.
CHECK_IN  = (Date.today + 30).to_s.freeze
CHECK_OUT = (Date.today + 33).to_s.freeze
NIGHTS    = 3

# Helper: iterate all properties to find first available room for CHECK_IN..CHECK_OUT.
# Multiple scenarios run sequentially against the same DB; earlier scenarios may
# exhaust room types at one property, so we iterate until availability is found.
find_available = lambda { |client, principal|
  props_resp = client.query(principal, name: "properties")
  all_props  = props_resp.body.is_a?(Hash) ? (props_resp.body["rows"] || []) : []
  raise "redteam(hoteling): no properties in catalog" if all_props.empty?

  all_props.each do |p|
    avail_resp = client.query(principal, name: "availability",
      property_id: p["property_id"], check_in: CHECK_IN, check_out: CHECK_OUT)
    avail_rows = avail_resp.body.is_a?(Hash) ? (avail_resp.body["rows"] || []) : []
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

  # ── per-user query — CrossTenantRead ─────────────────────────────────────
  per_user_query: "my_bookings",

  # ── row_id_key / result_id_key ────────────────────────────────────────────
  # Query rows (my_bookings) carry "booking_id" (the same name confirm_booking takes).
  # The reserve_room action response uses "booking_id" in body["value"].
  row_id_key:    "booking_id",
  result_id_key: "booking_id",

  # ── create_owned ─────────────────────────────────────────────────────────
  # Browse properties → check availability → reserve_room.
  # Iterates all properties to avoid exhausting a single property's room types.
  # Returns { id: booking_id, code: room_type_name, total_cents:, nights: }.
  create_owned: lambda { |client, principal|
    found = find_available.call(client, principal)
    prop  = found[:prop]
    room  = found[:room]

    rsv_resp = client.run(principal, name: "reserve_room",
      property_id:  prop["property_id"],
      room_type_id: room["room_type_id"],
      check_in:     CHECK_IN,
      check_out:    CHECK_OUT)
    raise "redteam(hoteling): reserve_room failed (#{rsv_resp.status}): #{rsv_resp.body.inspect}" \
      unless rsv_resp.status == 200

    booking_id    = rsv_resp.body.dig("value", "booking_id")
    total_cents   = rsv_resp.body.dig("value", "total_cents").to_i
    nightly_price = rsv_resp.body.dig("value", "nightly_price_cents").to_i

    {
      id:            booking_id,
      code:          room["name"],
      total_cents:   total_cents,
      nights:        NIGHTS,
      nightly_price: nightly_price,
    }
  },

  # ── forge_action / forge_args — ForgedUserId ─────────────────────────────
  # B calls reserve_room with user_id: A.user_id injected. The server must
  # derive the owning user from the GUC (kiosk.current_user_id()), not args.
  forge_action: "reserve_room",
  forge_args:   lambda { |client, principal_a, _principal_b|
    found = find_available.call(client, principal_a)
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

# A malformed booking_id must come back as a TYPED 400, never a 500 (K-581/K-582).
# Two surfaces, one guard (UuidCheck): confirm_booking's `booking_id` arg, and the
# `{"booking_id":…}` reference inside a signed cart mandate that the cashier
# prices at capture. Before the guard, Postgres raised InvalidTextRepresentation
# on the `::uuid` cast — not a Kiosk error, so it escaped as a raw 500 with the
# PG message attached, and on the PAY path a 500 is the worst possible answer
# because an assistant cannot tell it from "the charge may have gone through".
#
# Asserts three properties, not one: HTTP 400 (a client mistake reported as such),
# `error.code == "bad_request"` (typed, so an assistant can branch on it), and no
# SQL internals anywhere in the body. A generic `blocked?` verdict would accept a
# 403 or a 401 here, so this scenario builds its Verdict directly.
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
            client.run(a, name: "confirm_booking", booking_id: junk))
      check(failures, statuses, "pay cart booking_id=#{junk.inspect}",
            pay_with_ref(client, a, junk))
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

  def check(failures, statuses, label, resp)
    statuses << resp.status
    leak = SQL_INTERNALS.find { |needle| JSON.generate(resp.body).include?(needle) }
    code = resp.body.is_a?(Hash) ? resp.body.dig("error", "code") : nil
    return if resp.status == 400 && code == "bad_request" && leak.nil?

    failures << "#{label} → HTTP #{resp.status} code=#{code.inspect}#{leak ? " LEAKS #{leak.inspect}" : ""}"
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

# ── Scenario list ─────────────────────────────────────────────────────────────
#
# 13 generic + 3 local cashier-check beats; 3 generic (KYC variants) are expected
# to be skipped. 10 generic + 3 local are applicable (RegistrationWithoutPow now
# runs because register PoW is ON).

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
  WrongCurrencyCart.new,                                  # cashier check — currency
  TamperedPriceCart.new,                                  # cashier check — below quote
  InflatedTotalCart.new,                                  # cashier check — total ≠ line sum
  MalformedUuidArg.new,                                   # K-581/K-582 — junk uuid → typed 400, no 500
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
puts "  pow_difficulty: #{profile.pow_difficulty} (register PoW ON)"
puts "  requires_kyc:   false"
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
