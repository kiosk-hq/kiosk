# frozen_string_literal: true

# Concurrency regression for the pay-path double-charge races (K-544).
#
# Runs IN-PROCESS against the real getgrocery Postgres schema (via
# `bin/rails runner`), driving the REAL ValidatingPaymentProvider cashier check
# and the REAL create_order action across multiple threads (each on its own
# pooled connection, so Postgres row locks actually bite). The PSP is a
# controllable stub — a blocking latch (to hold a /pay mid-capture) or a
# counting stub (to see how many captures fire) — so we exercise the Kiosk
# serialization, not Stripe.
#
# It proves the two invariants the finding demands:
#   (a) SWAP: once a /pay for order O has begun (O is `paying`), a concurrent
#       create_order{order_id:O, items:[expensive]} CANNOT rewrite O's items —
#       so "pay €1, get €500" is impossible.
#   (b) AT-MOST-ONCE: under N racing /pay for one order, exactly ONE captures;
#       the rest are cleanly rejected.
#
# Exits 0 iff both hold; non-zero otherwise. Invoked by `rake demo:race`.

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
# would. Returns the action's result hash.
def create_order!(args)
  result = nil
  Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity) do
    result = Kiosk::Server::Actions.fetch("create_order").call(args)
  end
  result
end

def cart_for(order_id, id:, sku: CHEAP_SKU, qty: 1, price: CHEAP_PRICE)
  Kiosk::Mandate::CartMandate.new(
    id: id, intent_mandate_id: "intent-#{id}", user_id: USER_ID, agent_id: AGENT_ID,
    issuer: "https://getgrocery.demo", line_items: [{ order_id: order_id }, { sku: sku, qty: qty, price_cents: price }],
    total_amount_cents: qty * price, currency: "eur", expires_at: nil, created_at: nil, raw_jws: "cart-#{id}",
  )
end

def order_row(order_id)
  ActiveRecord::Base.connection.execute(
    "SELECT status, total_cents FROM orders WHERE id = '#{order_id}'::uuid LIMIT 1"
  ).first
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
order_id = o[:order_id]
puts "  order O=#{order_id} total=#{o[:total_cents]}c (cheap)"

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
check(swap[:order_id] != order_id,
      "create_order did NOT mutate O — it minted a separate order (#{swap[:order_id]}) instead of rewriting the in-flight one")

blocking.release!
pay_thread.join

check(blocking.charged_cents == CHEAP_PRICE,
      "the PSP was asked to charge the CHEAP amount (#{blocking.charged_cents}c), never the swapped-in expensive total")
check(order_row(order_id)["status"] == "paid", "order O settled to `paid` after capture")

puts "\n== K-544 (b): one order captures at most once under N racing /pay =="

n = 6
o2 = create_order!(items: [{ sku: CHEAP_SKU, qty: 1 }], delivery_slot_id: 3,
                   delivery_date: FUTURE, delivery_address: ADDRESS)
order2 = o2[:order_id]
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

# ── Verdict ─────────────────────────────────────────────────────────────────
puts
if FAILURES.empty?
  puts "K-544 concurrency spec: ALL PASS"
  puts JSON.generate(swap_blocked: true, at_most_once: true, captures_under_race: counting.count)
  exit 0
else
  puts "K-544 concurrency spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
