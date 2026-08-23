# frozen_string_literal: true

# Pay-path regression for getgrocery (K-544 concurrency, K-578 stuck-`paying`
# reconciliation, K-579 typed 4xx on a malformed order_id).
#
# Runs IN-PROCESS against the real getgrocery Postgres schema (via
# `bin/rails runner`), driving the REAL ValidatingPaymentProvider cashier check
# and the REAL create_order action across multiple threads (each on its own
# pooled connection, so Postgres row locks actually bite). The PSP is a
# controllable stub — a blocking latch (to hold a /pay mid-capture) or a
# counting stub (to see how many captures fire) — so we exercise the Kiosk
# serialization, not Stripe.
#
# It proves the invariants the findings demand:
#   (a) SWAP: once a /pay for order O has begun (O is `paying`), a concurrent
#       create_order{order_id:O, items:[expensive]} CANNOT rewrite O's items —
#       so "pay €1, get €500" is impossible.
#   (b) AT-MOST-ONCE: under N racing /pay for one order, exactly ONE captures;
#       the rest are cleanly rejected.
#   (c) TYPED REJECTION (K-579): a malformed order_id is a 400 bad_request at
#       every place one reaches an `::uuid` cast — the cart (before anything is
#       claimed or charged), create_order's replace path and reschedule_delivery
#       — never a raw 500, which an assistant cannot distinguish from "the
#       charge may have run".
#   (d) RECONCILIATION (K-578): an order stranded in `paying` because the
#       paid-flip was lost heals to `paid` from the settlement row (both at the
#       next /pay and via the sweep), while one whose outcome only the PSP knows
#       is reported UNRESOLVED and keeps its claim — never blind-released.
#
# Exits 0 iff all hold; non-zero otherwise. Invoked by `rake demo:race`.

require "json"

FAILURES = []

def check(cond, msg)
  if cond
    puts "  OK    #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

conn = ActiveRecord::Base.connection

# Shared quoting helper for every raw SQL string built below (K-715). A plain
# top-level local wouldn't reach the `def` methods further down — Ruby method
# bodies don't close over top-level locals — so this is a top-level method,
# callable from anywhere in this file.
def q(value)
  ActiveRecord::Base.connection.quote(value)
end

# ── Fixtures ────────────────────────────────────────────────────────────────
# One synthetic principal; a cheap and an (inflated-qty) expensive line drawn
# from the seeded catalog.
USER_ID  = "11111111-1111-1111-1111-111111111111"
AGENT_ID = "22222222-2222-2222-2222-222222222222"
ADDRESS  = "42 Camden Street, Dublin 2"
FUTURE   = (Date.today + 1).to_s

User.find_or_create_by!(id: USER_ID)

cheap = conn.execute("SELECT sku, price_cents FROM products WHERE sku = 'banana' LIMIT 1").first
dear  = conn.execute("SELECT sku, price_cents FROM products WHERE sku = 'olive-oil' LIMIT 1").first
abort "seed missing (run demo:setup first)" if cheap.nil? || dear.nil?
CHEAP_SKU   = cheap["sku"]
CHEAP_PRICE = cheap["price_cents"].to_i         # 149
DEAR_SKU    = dear["sku"]

# ── Helpers ─────────────────────────────────────────────────────────────────

def identity
  Kiosk::Identity.new(user_id: USER_ID, role: "customer", actor: "agent",
                      agent_id: AGENT_ID, claims: {})
end

# Invoke the REAL create_order action with the GUCs set, exactly as the wire
# would. Returns the action's result hash, with STRING keys.
#
# TWO THINGS THE T-057 MIGRATION CHANGED HERE, both of them properties of
# driving a CONTROLLER instead of a block, and both of them things a second
# surface on any demo has to get right (tudu found them first):
#
#   · `CurrentRequest.with` is now required as well as `SessionContext.open`.
#     The GUCs are what the SQL-side scoping reads; the IDENTITY CARRIER is what
#     `kiosk_identity` reads, and an INSERT has no predicate to hide the
#     principal in, so `create_order` needs both. The wire sets the two together;
#     a driver that sets only the GUCs gets a nil identity.
#   · the result comes back with STRING keys. A controller answers `render
#     json:`, and the dispatch seam parses that JSON — so `result["order_id"]`,
#     never `result[:order_id]`, which would be silently nil.
def create_order!(args)
  result = nil
  Kiosk::Server::CurrentRequest.with(identity: identity) do
    Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity) do
      result = Kiosk::Server::Actions.fetch("create_order").call(args)
    end
  end
  result
end

def cart_for(order_id, id:, sku: CHEAP_SKU, qty: 1, price: CHEAP_PRICE)
  Kiosk::Mandate::CartMandate.new(
    id: id, intent_mandate_id: "intent-#{id}", user_id: USER_ID, agent_id: AGENT_ID,
    issuer: "https://getgrocery.demo",
    # String keys, matching the wire: a cart arrives as a JWS, and the verifier
    # symbolises only the top-level claims, so the cashier always reads
    # line_items with String keys. This driver builds one in-process, so it is
    # the only place the shape could drift from what production hands over.
    line_items: [{ "order_id" => order_id }, { "sku" => sku, "qty" => qty, "price_cents" => price }],
    total_amount_cents: qty * price, currency: "eur", expires_at: nil, created_at: nil, raw_jws: "cart-#{id}",
  )
end

def order_row(order_id)
  ActiveRecord::Base.connection.execute(
    "SELECT status, total_cents FROM orders WHERE id = #{q(order_id)}::uuid LIMIT 1"
  ).first
end

# The `payment_state` the WIRE publishes for one order — read through the real
# `my_orders` query with the GUCs set, not out of the table, because the
# assertion is about what an assistant is TOLD (K-853).
def my_order_payment_state(order_id)
  rows = Kiosk::Server::CurrentRequest.with(identity: identity) do
    Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity) do
      Array(Kiosk::Server::Queries.fetch("my_orders").call({}))
    end
  end
  row = rows.find { |r| r["order_id"] == order_id }
  row && row["payment_state"]
end

# Settlement rows referencing this order. UNCACHED: `rails runner` wraps the
# script in the executor, which turns the ActiveRecord query cache on for this
# connection, and the writes we are watching for happen on OTHER connections —
# a cached count would re-read its own first answer and manufacture a verdict.
def settlements_for(order_id)
  Settlement.uncached do
    Settlement.joins(:cart_mandate).merge(CartMandate.referencing(order_id)).count
  end
end

# A PSP stub whose capture BLOCKS until released, recording the amount it was
# asked to charge — lets us pin an order in `paying` while we attack it.
class BlockingPsp
  attr_reader :charged_cents

  def initialize
    @gate = Queue.new
  end

  def capture(cart_mandate, payment_method: nil)
    @charged_cents = cart_mandate.total_amount_cents.to_i
    @gate.pop # block until released
    { psp_reference: "pi_stub_block", settled_amount_cents: @charged_cents, settled_at: Time.now.utc }
  end

  def release! = @gate << :go
  def setup_required?(*) = false
end

# A PSP stub that counts captures (thread-safe) and dawdles to widen the window.
class CountingPsp
  def initialize
    @mutex = Mutex.new
    @count = 0
  end

  def count = @mutex.synchronize { @count }

  def capture(cart_mandate, payment_method: nil)
    @mutex.synchronize { @count += 1 }
    sleep 0.05
    { psp_reference: "pi_stub_count", settled_amount_cents: cart_mandate.total_amount_cents.to_i, settled_at: Time.now.utc }
  end

  def setup_required?(*) = false
end

puts "\n== K-544 (a): items cannot be swapped once /pay has begun =="

# Create the cheap order O.
o = create_order!(items: [{ sku: CHEAP_SKU, qty: 1 }], delivery_slot_id: 3,
                  delivery_date: FUTURE, delivery_address: ADDRESS)
order_id = o["order_id"]
puts "  order O=#{order_id} total=#{o["total_cents"]}c (cheap)"

blocking = BlockingPsp.new
vpp      = ValidatingPaymentProvider.new(blocking, currency: "eur")

pay_thread = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    vpp.capture(cart_for(order_id, id: "cart-A"))
  end
end

# Wait until the pay has CLAIMED O (status → paying), i.e. it is mid-capture.
claimed = false
60.times do
  if order_row(order_id)["status"] == "paying"
    claimed = true
    break
  end
  sleep 0.05
end
check(claimed, "pay claimed order O (status → paying) before capture")

# ATTACK: while the pay is blocked mid-capture, try to swap O's items to an
# expensive line via create_order{order_id: O}.
swap = create_order!(items: [{ sku: DEAR_SKU, qty: 100 }], delivery_slot_id: 3,
                     delivery_date: FUTURE, delivery_address: ADDRESS, order_id: order_id)

o_after = order_row(order_id)
check(o_after["total_cents"].to_i == CHEAP_PRICE,
      "order O still holds the CHEAP total (#{o_after["total_cents"]}c == #{CHEAP_PRICE}c) — swap rejected")
check(swap["order_id"] != order_id,
      "create_order did NOT mutate O — it minted a separate order (#{swap["order_id"]}) instead of rewriting the in-flight one")

# ── K-853 (in-flight half): what my_orders publishes about O RIGHT NOW ───────
# The capture has STARTED and its outcome is unknown. protocol.md §11.6 forbids
# this from reading as *not paid*: that is the answer that licenses an assistant
# to sign a fresh mandate chain and charge its human a second time. It must be
# the third state, and O must not be missing from the answer either.
check(settlements_for(order_id).zero?, "no settlement row for O — the capture has not returned")
state_inflight = my_order_payment_state(order_id)
check(state_inflight == "pending",
      "my_orders publishes payment_state=pending for O while its capture is outstanding (got #{state_inflight.inspect})")
check(state_inflight != "unpaid",
      "my_orders does NOT publish `unpaid` for an order whose capture may already have taken the money")

blocking.release!
pay_thread.join

check(blocking.charged_cents == CHEAP_PRICE,
      "the PSP was asked to charge the CHEAP amount (#{blocking.charged_cents}c), never the swapped-in expensive total")
check(order_row(order_id)["status"] == "paid", "order O settled to `paid` after capture")

# ── K-853 (phase-3 half): capture RETURNED, settlement row not yet written ───
# The cashier was driven DIRECTLY here, so the engine's executor phase 3 never
# ran and no settlement row exists for O at all. That is the phase-3 window
# exactly, and the capture-anchored marker is the only witness there is.
check(settlements_for(order_id).zero?,
      "still no settlement row for O — the engine's phase 3 has not run (this IS the window)")
state_window = my_order_payment_state(order_id)
check(state_window == "paid",
      "my_orders publishes payment_state=paid for O on the CAPTURE alone, with zero settlement rows (got #{state_window.inspect})")

puts "\n== K-544 (b): one order captures at most once under N racing /pay =="

n = 6
o2 = create_order!(items: [{ sku: CHEAP_SKU, qty: 1 }], delivery_slot_id: 3,
                   delivery_date: FUTURE, delivery_address: ADDRESS)
order2 = o2["order_id"]
puts "  order O2=#{order2}; firing #{n} concurrent /pay"

counting = CountingPsp.new
vpp2     = ValidatingPaymentProvider.new(counting, currency: "eur")
results  = Queue.new

mutex = Mutex.new
cond  = ConditionVariable.new
ready = 0
go    = false

threads = n.times.map do |i|
  Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do
      # Barrier: line all N up, then release together.
      mutex.synchronize do
        ready += 1
        cond.broadcast
        cond.wait(mutex) until go
      end
      begin
        vpp2.capture(cart_for(order2, id: "cart-B#{i}"))
        results << :ok
      rescue Kiosk::Server::Errors::Forbidden => e
        results << [:denied, e.message]
      rescue StandardError => e
        results << [:error, "#{e.class}: #{e.message}"]
      end
    end
  end
end

mutex.synchronize do
  cond.wait(mutex) until ready == n
  go = true
  cond.broadcast
end
threads.each(&:join)

outcomes = []
outcomes << results.pop until results.empty?
oks     = outcomes.count { |o| o == :ok }
denied  = outcomes.count { |o| o.is_a?(Array) && o.first == :denied }
errored = outcomes.select { |o| o.is_a?(Array) && o.first == :error }

check(counting.count == 1, "exactly ONE capture fired across #{n} racing pays (got #{counting.count})")
check(oks == 1,            "exactly ONE /pay succeeded (got #{oks})")
check(denied == n - 1,     "the other #{n - 1} /pay were cleanly rejected (got #{denied} denied)")
check(errored.empty?,      "no /pay produced a raw error (got #{errored.inspect})")
check(order_row(order2)["status"] == "paid", "order O2 settled to `paid`")

puts "\n== K-579: a malformed order_id is a typed 4xx, never a 500 =="

# The cart's {"order_id": …} entry lands in an `::uuid` cast. A malformed one
# used to reach Postgres, raise InvalidTextRepresentation and escape as a raw
# 500 — the worst answer on a pay path, since an assistant cannot tell a
# rejected input from "the charge may have gone through".
bad_psp = CountingPsp.new
vpp3    = ValidatingPaymentProvider.new(bad_psp, currency: "eur")

bad_error = begin
  vpp3.capture(cart_for("not-a-uuid", id: "cart-BAD"))
  nil
rescue StandardError => e
  e
end

check(bad_error.is_a?(Kiosk::Server::Errors::BadRequest),
      "a malformed order_id raises BadRequest (got #{bad_error.class})")
check(bad_error.respond_to?(:http_status) && bad_error.http_status == 400,
      "…rendered as HTTP 400 (got #{bad_error.respond_to?(:http_status) ? bad_error.http_status : "n/a"})")
check(bad_error.respond_to?(:code) && bad_error.code == "bad_request",
      "…carrying the wire code bad_request (got #{bad_error.respond_to?(:code) ? bad_error.code : "n/a"})")
check(bad_psp.count.zero?, "…and NOTHING was sent to the PSP (captures=#{bad_psp.count})")

# A well-formed uuid that is not the payer's order still gets the ownership
# rejection, not a 400 — the shape check must not swallow the authz answer.
unknown_error = begin
  vpp3.capture(cart_for("00000000-0000-4000-8000-000000000000", id: "cart-UNKNOWN"))
  nil
rescue StandardError => e
  e
end
check(unknown_error.is_a?(Kiosk::Server::Errors::Forbidden),
      "a well-formed but foreign order_id still gets the ownership rejection (got #{unknown_error.class})")

# The cashier is one of THREE places a wire-supplied id reaches an `::uuid`
# cast; the same `UuidCheck` guard covers the other two, and they are actions,
# so drive them through the real registry here rather than trusting the shape of
# the code. (A DB-free unit pass over the guard itself is `rake demo:cashier_spec`.)
def action_error(name, args)
  Kiosk::Server::CurrentRequest.with(identity: identity) do
    Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity) do
      Kiosk::Server::Actions.fetch(name).call(args)
    end
  end
  nil
rescue StandardError => e
  e
end

replace_error = action_error("create_order",
                             { order_id: "not-a-uuid", items: [{ sku: CHEAP_SKU, qty: 1 }],
                               delivery_slot_id: 3, delivery_date: FUTURE, delivery_address: ADDRESS })
# The CODE and the STATUS are the contract, not the exception class (T-054): a
# migrated handler RENDERS its refusal and the dispatch seam turns that into a
# `WireError` carrying the same code and status the raised `Errors::BadRequest`
# used to. Asserting the class here would be asserting how the answer is
# constructed rather than what it says.
check(replace_error.respond_to?(:code) && replace_error.code == "bad_request" && replace_error.http_status == 400,
      "create_order's replace path rejects a malformed order_id with a 400 bad_request (got #{replace_error.class})")

reschedule_error = action_error("reschedule_delivery",
                                { order_id: "not-a-uuid", delivery_slot_id: 3, delivery_date: FUTURE })
check(reschedule_error.respond_to?(:code) && reschedule_error.code == "bad_request" && reschedule_error.http_status == 400,
      "reschedule_delivery rejects a malformed order_id with a 400 bad_request (got #{reschedule_error.class})")

puts "\n== K-578: an order stuck in `paying` is reconciled from local evidence =="

# Simulate the crash the finding describes: the capture SUCCEEDED and the
# engine recorded the settlement (executor P3), but the local `paying → paid`
# flip was lost. The order is charged once and would otherwise sit `paying`
# forever, unpayable.
def forge_settlement!(order_id, cart_mandate_id:)
  conn = ActiveRecord::Base.connection
  intent_row = conn.execute(
    "INSERT INTO kiosk.intent_mandates (mandate_id, user_id, agent_id, issuer, scope, " \
    "cap_amount_cents, currency, expires_at, created_at, raw_jws) " \
    "VALUES (#{q("intent-#{cart_mandate_id}")}, #{q(USER_ID)}::uuid, #{q(AGENT_ID)}::uuid, " \
    "#{q('https://getgrocery.demo')}, #{q('grocery')}, #{q(100_000)}, #{q('eur')}, " \
    "now() + interval '1 hour', now(), #{q('jws')}) RETURNING id"
  ).first["id"]
  cart_row = conn.execute(
    "INSERT INTO kiosk.cart_mandates (mandate_id, intent_mandate_id, user_id, agent_id, issuer, " \
    "line_items, total_amount_cents, currency, expires_at, created_at, raw_jws) " \
    "VALUES (#{q(cart_mandate_id)}, #{q(intent_row.to_s)}::uuid, #{q(USER_ID)}::uuid, " \
    "#{q(AGENT_ID)}::uuid, #{q('https://getgrocery.demo')}, " \
    "#{q([{ order_id: order_id }].to_json)}::jsonb, #{q(CHEAP_PRICE)}, #{q('eur')}, " \
    "now() + interval '1 hour', now(), #{q('jws')}) RETURNING id"
  ).first["id"]
  conn.execute(
    "INSERT INTO kiosk.settlements (cart_mandate_id, user_id, agent_id, issuer, psp_reference, " \
    "settled_amount_cents, currency, settled_at, raw_jws) " \
    "VALUES (#{q(cart_row.to_s)}::uuid, #{q(USER_ID)}::uuid, #{q(AGENT_ID)}::uuid, " \
    "#{q('https://getgrocery.demo')}, #{q('pi_forged_receipt')}, #{q(CHEAP_PRICE)}, #{q('eur')}, now(), #{q('jws')})"
  )
end

def strand_as_paying!(order_id, age: "1 hour")
  ActiveRecord::Base.connection.execute(
    "UPDATE orders SET status = 'paying', updated_at = now() - #{q(age)}::interval " \
    "WHERE id = #{q(order_id)}::uuid"
  )
end

o3 = create_order!(items: [{ sku: CHEAP_SKU, qty: 1 }], delivery_slot_id: 3,
                   delivery_date: FUTURE, delivery_address: ADDRESS)
charged_order = o3["order_id"]
strand_as_paying!(charged_order)
forge_settlement!(charged_order, cart_mandate_id: "cart-CHARGED")
check(order_row(charged_order)["status"] == "paying", "order is stranded in `paying` with a settlement on file")

# (a) The next /pay tells the truth and heals the row on the spot.
heal_psp = CountingPsp.new
heal_err = begin
  ValidatingPaymentProvider.new(heal_psp, currency: "eur").capture(cart_for(charged_order, id: "cart-RETRY"))
  nil
rescue StandardError => e
  e
end
check(heal_err.is_a?(Kiosk::Server::Errors::Forbidden) && heal_err.message.include?("already settled"),
      "a retry on the stranded order answers `order already settled` (got #{heal_err.class}: #{heal_err&.message})")
check(heal_psp.count.zero?, "…and the PSP was NOT charged a second time (captures=#{heal_psp.count})")
check(order_row(charged_order)["status"] == "paid",
      "…and the stranded order self-healed `paying` → `paid`")

# (b) The sweep heals what local evidence proves — and REFUSES to guess on
#     what it cannot, leaving the claim in place so no blind retry can
#     double-charge (K-545).
strand_as_paying!(charged_order) # strand it again for the sweep

o4 = create_order!(items: [{ sku: CHEAP_SKU, qty: 1 }], delivery_slot_id: 3,
                   delivery_date: FUTURE, delivery_address: ADDRESS)
unknown_order = o4["order_id"]
strand_as_paying!(unknown_order) # claimed, NO settlement — only the PSP knows

o5 = create_order!(items: [{ sku: CHEAP_SKU, qty: 1 }], delivery_slot_id: 3,
                   delivery_date: FUTURE, delivery_address: ADDRESS)
young_order = o5["order_id"]
strand_as_paying!(young_order, age: "1 second") # a pay legitimately in flight

sweep = ValidatingPaymentProvider.reconcile_stuck_paying!(older_than_seconds: 600)
unresolved_ids = sweep[:unresolved].map { |r| r[:order_id] }

check(sweep[:healed].include?(charged_order), "sweep healed the settled order (healed=#{sweep[:healed].size})")
check(order_row(charged_order)["status"] == "paid", "…its status is `paid`")
check(unresolved_ids.include?(unknown_order), "sweep reported the unprovable order as UNRESOLVED")
check(order_row(unknown_order)["status"] == "paying",
      "…and did NOT release its claim (a blind retry stays impossible)")
check(sweep[:unresolved].find { |r| r[:order_id] == unknown_order }[:cart_mandate_ids].is_a?(Array),
      "…reporting the cart-mandate ids to look the charge up at the processor")
check(!sweep[:healed].include?(young_order) && !unresolved_ids.include?(young_order),
      "a freshly-claimed order (pay still in flight) is left alone by the sweep")

# ── Verdict ─────────────────────────────────────────────────────────────────
puts
if FAILURES.empty?
  puts "getgrocery pay-path spec (K-544/K-578/K-579): ALL PASS"
  puts JSON.generate(swap_blocked: true, at_most_once: true, captures_under_race: counting.count,
                     malformed_order_id: "bad_request", stuck_paying_healed: true)
  exit 0
else
  puts "getgrocery pay-path spec (K-544/K-578/K-579): #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
