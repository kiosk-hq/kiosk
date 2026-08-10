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
      "…with error.code=bad_request (got #{bad_error.respond_to?(:code) ? bad_error.code : "n/a"})")
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
  Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity) do
    Kiosk::Server::Actions.fetch(name).call(args)
  end
  nil
rescue StandardError => e
  e
end

replace_error = action_error("create_order",
                             { order_id: "not-a-uuid", items: [{ sku: CHEAP_SKU, qty: 1 }],
                               delivery_slot_id: 3, delivery_date: FUTURE, delivery_address: ADDRESS })
check(replace_error.is_a?(Kiosk::Server::Errors::BadRequest) && replace_error.http_status == 400,
      "create_order's replace path rejects a malformed order_id with a 400 (got #{replace_error.class})")

reschedule_error = action_error("reschedule_delivery",
                                { order_id: "not-a-uuid", delivery_slot_id: 3, delivery_date: FUTURE })
check(reschedule_error.is_a?(Kiosk::Server::Errors::BadRequest) && reschedule_error.http_status == 400,
      "reschedule_delivery rejects a malformed order_id with a 400 (got #{reschedule_error.class})")

puts "\n== K-578: an order stuck in `paying` is reconciled from local evidence =="

# Simulate the crash the finding describes: the capture SUCCEEDED and the
# engine recorded the settlement (executor P3), but the local `paying → paid`
# flip was lost. The order is charged once and would otherwise sit `paying`
# forever, unpayable.
def forge_settlement!(order_id, cart_mandate_id:)
  conn = ActiveRecord::Base.connection
  q    = ->(v) { conn.quote(v) }
  intent_row = conn.execute(
    "INSERT INTO kiosk.intent_mandates (mandate_id, user_id, agent_id, issuer, scope, " \
    "cap_amount_cents, currency, expires_at, created_at, raw_jws) " \
    "VALUES (#{q.call("intent-#{cart_mandate_id}")}, #{q.call(USER_ID)}::uuid, #{q.call(AGENT_ID)}::uuid, " \
    "'https://getgrocery.demo', 'grocery', 100000, 'eur', now() + interval '1 hour', now(), 'jws') RETURNING id"
  ).first["id"]
  cart_row = conn.execute(
    "INSERT INTO kiosk.cart_mandates (mandate_id, intent_mandate_id, user_id, agent_id, issuer, " \
    "line_items, total_amount_cents, currency, expires_at, created_at, raw_jws) " \
    "VALUES (#{q.call(cart_mandate_id)}, #{q.call(intent_row.to_s)}::uuid, #{q.call(USER_ID)}::uuid, " \
    "#{q.call(AGENT_ID)}::uuid, 'https://getgrocery.demo', " \
    "#{q.call([{ order_id: order_id }].to_json)}::jsonb, #{CHEAP_PRICE}, 'eur', " \
    "now() + interval '1 hour', now(), 'jws') RETURNING id"
  ).first["id"]
  conn.execute(
    "INSERT INTO kiosk.settlements (cart_mandate_id, user_id, agent_id, issuer, psp_reference, " \
    "settled_amount_cents, currency, settled_at, raw_jws) " \
    "VALUES (#{q.call(cart_row.to_s)}::uuid, #{q.call(USER_ID)}::uuid, #{q.call(AGENT_ID)}::uuid, " \
    "'https://getgrocery.demo', 'pi_forged_receipt', #{CHEAP_PRICE}, 'eur', now(), 'jws')"
  )
end

def strand_as_paying!(order_id, age: "1 hour")
  ActiveRecord::Base.connection.execute(
    "UPDATE orders SET status = 'paying', updated_at = now() - interval '#{age}' " \
    "WHERE id = '#{order_id}'::uuid"
  )
end

o3 = create_order!(items: [{ sku: CHEAP_SKU, qty: 1 }], delivery_slot_id: 3,
                   delivery_date: FUTURE, delivery_address: ADDRESS)
charged_order = o3[:order_id]
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
unknown_order = o4[:order_id]
strand_as_paying!(unknown_order) # claimed, NO settlement — only the PSP knows

o5 = create_order!(items: [{ sku: CHEAP_SKU, qty: 1 }], delivery_slot_id: 3,
                   delivery_date: FUTURE, delivery_address: ADDRESS)
young_order = o5[:order_id]
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
