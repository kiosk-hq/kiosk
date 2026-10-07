# frozen_string_literal: true

# Stuck-`paying` reconciliation for getgrocery: the three answers a payment
# processor can give about a capture, and what each one does to the claim.
#
# Runs IN-PROCESS against the real getgrocery Postgres schema (via
# `bin/rails runner`), driving the REAL sweep over orders stranded exactly as a
# crash between a successful capture and the paid-flip strands them.
#
#   (a) CHARGED       — the processor says the money moved: `paying` → `paid`.
#   (b) NOT CHARGED   — it says no money moved: the claim is released and the
#                       order is `created` and payable again.
#   (c) NO ANSWER     — it cannot say: the order is UNRESOLVED, keeps its
#                       claim, and is reported with the cart-mandate ids to look
#                       up by hand. Releasing it is the blind retry that charges
#                       a human twice.
#   (d) LOCAL FIRST   — a settlement row already proves the charge, so that
#                       order is healed without the processor being asked at all.
#
# Two processors drive it. A SCRIPTED one answers each of the three ways, which
# is the only way (a) and (b) can be reached without moving real money. The real
# {Kiosk::PaymentProviders::Stripe::ChargeLookup} then runs against a local stripe-mock, whose canned
# PaymentIntent fixture is in a status that would RELEASE a claim — and does
# not, because it names no cart of ours. That is the whole of what makes a
# processor answer usable as evidence.
#
# Exits 0 iff all hold; non-zero otherwise. Invoked by `rake check:reconcile`.

require "json"
require "securerandom"

FAILURES = []

def check(cond, msg)
  if cond
    puts "  OK    #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

def q(value)
  ActiveRecord::Base.connection.quote(value)
end

# A processor that answers from a script instead of over a network, and records
# what it was asked. `fetch` raises on an id nobody scripted, so a sweep that
# looked up the wrong cart fails here rather than silently.
class ScriptedProcessor
  attr_reader :asked

  def initialize(answers)
    @answers = answers
    @asked   = []
  end

  def outcome(cart_mandate_id:, amount_cents:, currency:)
    @asked << [cart_mandate_id, amount_cents, currency]
    @answers.fetch(cart_mandate_id)
  end
end

# ── Fixtures ────────────────────────────────────────────────────────────────
USER_ID  = "33333333-3333-3333-3333-333333333333"
AGENT_ID = "44444444-4444-4444-4444-444444444444"
ADDRESS  = "42 Camden Street, Dublin 2"
FUTURE   = (Date.today + 1).to_s

User.find_or_create_by!(id: USER_ID)
EVENTS_HEAD = Kiosk.configuration.event_store.head

cheap = ActiveRecord::Base.connection.execute(
  "SELECT sku, price_cents FROM products WHERE sku = 'banana' LIMIT 1"
).first
abort "seed missing (run demo:setup first)" if cheap.nil?
CHEAP_SKU   = cheap["sku"]
CHEAP_PRICE = cheap["price_cents"].to_i

def identity
  Kiosk::Identity.new(user_id: USER_ID, role: "customer", actor: "agent",
                      agent_id: AGENT_ID, claims: {})
end

# Place an order through the REAL create_order action, with the GUCs and the
# identity carrier the wire sets — the only way to get a row whose slot, zone
# and total are what production would have written.
def place_order!
  result = nil
  Kiosk::Server::CurrentRequest.with(identity: identity) do
    Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity) do
      result = Kiosk::Server::Actions.fetch("create_order").call(
        items: [{ sku: CHEAP_SKU, qty: 1 }], delivery_slot_id: 3,
        delivery_date: FUTURE, delivery_address: ADDRESS,
      )
    end
  end
  result["order_id"]
end

# The cart mandate the engine persists BEFORE the capture (executor phase 1).
# It exists for every stranded order, which is what makes the charge findable at
# the processor at all — the Stripe adapter stamps its id on the PaymentIntent.
def persist_cart_mandate!(order_id, cart_mandate_id:)
  conn = ActiveRecord::Base.connection
  intent_id = conn.execute(
    "INSERT INTO kiosk.intent_mandates (mandate_id, user_id, agent_id, issuer, scope, " \
    "cap_amount_cents, currency, expires_at, created_at, raw_jws) " \
    "VALUES (#{q("intent-#{cart_mandate_id}")}, #{q(USER_ID)}::uuid, #{q(AGENT_ID)}::uuid, " \
    "#{q('https://getgrocery.demo')}, #{q('grocery')}, #{q(100_000)}, #{q('eur')}, " \
    "now() + interval '1 hour', now(), #{q('jws')}) RETURNING id"
  ).first["id"]
  conn.execute(
    "INSERT INTO kiosk.cart_mandates (mandate_id, intent_mandate_id, user_id, agent_id, issuer, " \
    "line_items, total_amount_cents, currency, expires_at, created_at, raw_jws) " \
    "VALUES (#{q(cart_mandate_id)}, #{q(intent_id.to_s)}::uuid, #{q(USER_ID)}::uuid, " \
    "#{q(AGENT_ID)}::uuid, #{q('https://getgrocery.demo')}, " \
    "#{q([{ order_id: order_id }].to_json)}::jsonb, #{q(CHEAP_PRICE)}, #{q('eur')}, " \
    "now() + interval '1 hour', now(), #{q('jws')}) RETURNING id"
  ).first["id"]
end

def forge_settlement!(cart_row_id)
  ActiveRecord::Base.connection.execute(
    "INSERT INTO kiosk.settlements (cart_mandate_id, user_id, agent_id, issuer, psp_reference, " \
    "settled_amount_cents, currency, settled_at) " \
    "VALUES (#{q(cart_row_id.to_s)}::uuid, #{q(USER_ID)}::uuid, #{q(AGENT_ID)}::uuid, " \
    "#{q('https://getgrocery.demo')}, #{q('pi_forged_receipt')}, #{q(CHEAP_PRICE)}, #{q('eur')}, now())"
  )
end

def strand!(order_id, age: "1 hour")
  ActiveRecord::Base.connection.execute(
    "UPDATE orders SET status = 'paying', updated_at = now() - #{q(age)}::interval " \
    "WHERE id = #{q(order_id)}::uuid"
  )
end

def status_of(order_id)
  ActiveRecord::Base.connection.execute(
    "SELECT status FROM orders WHERE id = #{q(order_id)}::uuid LIMIT 1"
  ).first["status"]
end

# ── The three answers, and local evidence ahead of all of them ──────────────
puts "\n── A processor that answers, and a sweep that acts on each answer ──"

charged   = place_order!
declined  = place_order!
silent    = place_order!
settled   = place_order!
young     = place_order!

mandates = { charged => "cart-CHARGED", declined => "cart-DECLINED",
             silent => "cart-SILENT", settled => "cart-SETTLED", young => "cart-YOUNG" }
cart_rows = mandates.to_h { |order_id, mandate| [order_id, persist_cart_mandate!(order_id, cart_mandate_id: mandate)] }
forge_settlement!(cart_rows.fetch(settled))

mandates.each_key { |order_id| strand!(order_id) }
strand!(young, age: "1 second") # a pay legitimately still in flight

processor = ScriptedProcessor.new(
  "cart-CHARGED" => :paid, "cart-DECLINED" => :not_charged, "cart-SILENT" => :unknown,
)
sweep = Kiosk.configuration.payment_provider.reconcile_stuck_paying!(lookup: processor, older_than_seconds: 600)
unresolved_ids = sweep[:unresolved].map { |row| row[:order_id] }

charged_healed = sweep[:healed].include?(charged)
charged_paid   = status_of(charged) == "paid"
check(charged_healed, "the processor says CHARGED → healed (healed=#{sweep[:healed].size})")
check(charged_paid, "…and the order is `paid`")

declined_released = sweep[:released].include?(declined)
declined_payable  = status_of(declined) == "created"
check(declined_released, "the processor says NOT CHARGED → released (released=#{sweep[:released].size})")
check(declined_payable, "…and the order is back at `created`, payable again")

silent_unresolved = unresolved_ids.include?(silent)
silent_claim_kept = status_of(silent) == "paying"
check(silent_unresolved, "the processor CANNOT SAY → UNRESOLVED")
check(silent_claim_kept, "…and the claim is kept (a blind retry stays impossible)")
check(sweep[:unresolved].find { |row| row[:order_id] == silent }[:cart_mandate_ids] == ["cart-SILENT"],
      "…reported with the cart-mandate id to look up by hand")

check(sweep[:healed].include?(settled) && status_of(settled) == "paid",
      "a settlement row heals the order on local evidence alone")
check(processor.asked.none? { |(mandate, _, _)| mandate == "cart-SETTLED" },
      "…and the processor was never asked about it")

check(processor.asked.include?(["cart-CHARGED", CHEAP_PRICE, "eur"]),
      "the processor is asked about the CART — its id, its amount and its currency")

check(!sweep[:healed].include?(young) && !sweep[:released].include?(young) && !unresolved_ids.include?(young),
      "a freshly-claimed order (pay still in flight) is left alone by the sweep")

paid_events = Kiosk.configuration.event_store.since(USER_ID, EVENTS_HEAD)
                   .select { |e| e["topic"] == "order_payment" }
check(paid_events.map { |e| e["subject"] }.sort == [charged, settled].sort,
      "each healed order pushed one order_payment event to its owner (got #{paid_events.size})")
errors = Kiosk::Redteam::EventStream.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), paid_events)
check(errors.empty?, "every order_payment `data` satisfies the payload_schema #{errors.first(3).join("; ")}".strip)

# ── The same sweep against stripe-mock, through the real lookup ─────────────
puts "\n── The real ChargeLookup against stripe-mock ──"

mock_url = Rails.configuration.x.kiosk.stripe_mock_url
abort "STRIPE_MOCK_URL is unset — this check must never reach Stripe" if mock_url.blank?
abort "Stripe.api_base is #{::Stripe.api_base.inspect}, not the local mock" unless ::Stripe.api_base == mock_url

mock_order   = place_order!
mock_mandate = "cart-MOCK-#{SecureRandom.uuid}"
persist_cart_mandate!(mock_order, cart_mandate_id: mock_mandate)
strand!(mock_order)

canned = ::Stripe::PaymentIntent.search(query: "metadata['cart_mandate_id']:'#{mock_mandate}'").data
check(canned.any?, "stripe-mock answers the search with a canned intent (#{canned.size})")
check(Kiosk::PaymentProviders::Stripe::ChargeLookup::NOT_CHARGED.include?(canned.first.status),
      "…in a status that would RELEASE a claim on its own (#{canned.first.status})")

lookup       = Kiosk::PaymentProviders::Stripe::ChargeLookup.new
mock_outcome = lookup.outcome(cart_mandate_id: mock_mandate, amount_cents: CHEAP_PRICE, currency: "eur")
check(mock_outcome == :unknown,
      "…and the evidence check refuses it: it names no cart, amount or currency of ours")

mock_sweep = Kiosk.configuration.payment_provider.reconcile_stuck_paying!(lookup: lookup, older_than_seconds: 600)
check(mock_sweep[:unresolved].map { |row| row[:order_id] }.include?(mock_order),
      "so the sweep reports the order UNRESOLVED")
check(mock_sweep[:released].empty?, "…releases nothing (released=#{mock_sweep[:released].size})")
check(status_of(mock_order) == "paying", "…and the claim is kept")

# ── Verdict ─────────────────────────────────────────────────────────────────
#
# Every member is READ OFF the run — the value its own `check` above asserted on
# — and the line prints whatever the outcome, so a breach shows up in it instead
# of suppressing it. The exit code follows FAILURES, which is what `rake
# check:reconcile` reads.
puts
puts JSON.generate(healed:               charged_healed && charged_paid,
                   released:             declined_released && declined_payable,
                   unresolved:           silent_unresolved && silent_claim_kept,
                   mock_fixture_refused: mock_outcome == :unknown)
if FAILURES.empty?
  puts "getgrocery stuck-`paying` reconciliation: ALL PASS"
  exit 0
else
  puts "getgrocery stuck-`paying` reconciliation: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
