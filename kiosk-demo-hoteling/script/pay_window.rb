# frozen_string_literal: true

# THE CAPTURE→SETTLEMENT WINDOW, pinned (K-853 / protocol.md §11.6).
#
# Runs IN-PROCESS against the real hoteling Postgres schema (via
# `bin/rails runner`), driving the REAL `reserve_room` / `my_bookings` /
# `confirm_booking` verbs and the REAL ValidatingBookingProvider cashier, with a
# CONTROLLABLE PSP stub so the two halves of the window can actually be stood in:
#
#   · a BLOCKING capture holds a booking mid-charge — the capture has STARTED and
#     its outcome is unknown;
#   · calling the provider DIRECTLY means the engine's executor phase 3 never
#     runs, so the capture RETURNS with no settlement row in existence. That is
#     the phase-3 window exactly, and it is the state hoteling used to publish as
#     "no settlement for this booking".
#
# §11.6 forbids both of those from reading as *not paid*: "Absence of a
# settlement record is not evidence that no money moved, and an operator that
# publishes it as one is telling every assistant to charge its human twice."
#
# WHAT IT PROVES
#   (a) POSITIVE CONTROL — a booking nobody has paid for reads `unpaid`. Without
#       this the tri-state could be satisfied by never saying unpaid at all,
#       which would break the ONE answer that makes a fresh chain correct.
#   (b) IN FLIGHT        — while a capture is blocked mid-charge, my_bookings
#       reads `pending` (never `unpaid`), no settlement row exists, and
#       confirm_booking refuses with the pending sentence rather than "no
#       settlement".
#   (c) PHASE-3 WINDOW   — after the capture RETURNS and before any settlement
#       row exists, my_bookings reads `paid` and confirm_booking succeeds on the
#       capture-anchored witness alone.
#   (d) AT MOST ONCE     — under N racing /pay for one booking, exactly ONE
#       reaches the PSP; the rest are refused before any capture.
#   (e) NEVER A BARE NO  — across every observation above, `unpaid` is published
#       only in state (a). Asserted as a collected transcript, so a regression
#       that reintroduces the settlement-only read fails here loudly.
#
# Exits 0 iff all hold; non-zero otherwise. Invoked by `rake demo:book`.

require "json"

# EAGER-LOAD before anything threads. `rails runner` wraps the script in the
# executor, which holds the autoload interlock in SHARING mode for the whole
# run; a background thread that has to autoload a constant needs it EXCLUSIVELY
# and stalls until this thread happens to release. That stall is not the race
# under test — it is an artefact of driving the app from a script — and it made
# the claim look seconds late. Loading everything up front removes it.
Rails.application.eager_load!

FAILURES = []

def check(cond, msg)
  if cond
    puts "  OK    #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

# ── Fixtures ────────────────────────────────────────────────────────────────
# One synthetic principal, and a seeded room type to book against. Each booking
# takes its OWN future date range: the `bookings_no_overlapping_room_nights`
# EXCLUDE constraint would otherwise refuse the second reserve.
USER_ID  = "33333333-3333-3333-3333-333333333333"
AGENT_ID = "44444444-4444-4444-4444-444444444444"

User.find_or_create_by!(id: USER_ID)

# Re-runnable without a re-seed. This principal is this script's alone, and its
# bookings hold room-nights under the `bookings_no_overlapping_room_nights`
# EXCLUDE constraint — so a second run would be refused by the FIRST run's holds
# rather than by anything under test.
RoomHold.where(user_id: USER_ID).delete_all
Booking.where(user_id: USER_ID).delete_all

room = RoomType.order(:id).first
abort "seed missing (run demo:setup first)" if room.nil?
PROPERTY_ID    = room.property_id
ROOM_TYPE_ID   = room.id
NIGHTLY_CENTS  = room.nightly_price_cents

@next_offset = 400

# A fresh, non-overlapping [check_in, check_out) for the seeded room type.
def next_stay
  @next_offset += 3
  [(Date.today + @next_offset).to_s, (Date.today + @next_offset + 1).to_s]
end

def identity
  Kiosk::Identity.new(user_id: USER_ID, role: "customer", actor: "agent",
                      agent_id: AGENT_ID, claims: {})
end

# Invoke a REAL verb with the GUCs and the identity carrier set, exactly as the
# wire does. Both are needed: the GUCs are what the SQL-side scoping reads, the
# carrier is what `kiosk_identity` reads. A controller answers `render json:`
# and the dispatch seam parses that JSON, so results come back STRING-keyed.
def call_verb(registry, name, args)
  result = nil
  Kiosk::Server::CurrentRequest.with(identity: identity) do
    Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity) do
      result = registry.fetch(name).call(args)
    end
  end
  result
end

def reserve!
  check_in, check_out = next_stay
  call_verb(Kiosk::Server::Actions, "reserve_room",
            property_id: PROPERTY_ID, room_type_id: ROOM_TYPE_ID,
            check_in: check_in, check_out: check_out)
end

# A migrated handler RENDERS its refusal and the dispatch seam turns that into a
# `WireError`, so a refusal ARRIVES as a raised object carrying `code`,
# `http_status` and `message` — the contract, rather than the exception class
# (T-054). Returns the error, or nil when the call succeeded.
def verb_error(registry, name, args)
  call_verb(registry, name, args)
  nil
rescue StandardError => e
  e
end

def my_bookings = Array(call_verb(Kiosk::Server::Queries, "my_bookings", {}))

# The `payment_state` my_bookings publishes for ONE booking, and every one it
# has ever published for it — the transcript assertion (e) reads.
OBSERVED = Hash.new { |h, k| h[k] = [] }

def payment_state(booking_id)
  row   = my_bookings.find { |r| r["booking_id"] == booking_id }
  state = row && row["payment_state"]
  OBSERVED[booking_id] << state
  state
end

def cart_for(booking_id, id:, total_cents: NIGHTLY_CENTS, user_id: USER_ID)
  Kiosk::Mandate::CartMandate.new(
    id: id, intent_mandate_id: "intent-#{id}", user_id: user_id, agent_id: AGENT_ID,
    issuer: "https://hoteling.demo",
    # String keys, matching the wire: a cart arrives as a JWS, and the verifier
    # symbolises only the top-level claims, so the cashier always reads
    # line_items with String keys. This driver builds one in-process, so it is
    # the only place the shape could drift from what production hands over.
    line_items: [{ "booking_id" => booking_id },
                 { "sku" => "room-night", "qty" => 1, "price_cents" => total_cents }],
    total_amount_cents: total_cents, currency: "eur", expires_at: nil, created_at: nil,
    raw_jws: "cart-#{id}",
  )
end

# UNCACHED, and that is load-bearing rather than defensive. `rails runner` wraps
# the script in the executor, which turns the ActiveRecord QUERY CACHE on for
# this connection — and the write we are waiting for happens on ANOTHER
# connection, so nothing invalidates it. Cached, this poll re-reads its own first
# answer forever and reports "the pay never claimed" about a booking that was
# claimed milliseconds later. A stale read that manufactures a verdict is the one
# failure this whole script exists to make impossible; it does not get to have it.
def booking_payment_status(booking_id)
  Booking.uncached { Booking.where(id: booking_id).pick(:payment_status) }
end

# Wait for a background pay thread to reach a state, WITHOUT holding the
# autoload interlock while we do. `rails runner` wraps the script in the
# executor, which holds the load interlock in sharing mode for the whole run; a
# thread that has to AUTOLOAD a constant (the cashier, {UuidCheck}, the models
# it touches) needs it exclusively and would block until this loop gave up —
# which is not the race under test, just an artefact of driving the app from a
# script. `permit_concurrent_loads` releases the share for the duration of the
# sleep, which is exactly what it is for.
def wait_until(seconds: 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    return true if yield
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { sleep 0.05 }
  end
end

def settlements_for(booking_id)
  Settlement.uncached do
    Settlement.joins(:cart_mandate).merge(CartMandate.referencing(booking_id)).count
  end
end

# A PSP stub whose capture BLOCKS until released — lets us pin a booking
# mid-charge and read what the operator publishes about it.
class BlockingPsp
  def initialize
    @gate = Queue.new
  end

  def capture(cart_mandate, payment_method: nil)
    @gate.pop
    { psp_reference: "stub_pi_block", settled_amount_cents: cart_mandate.total_amount_cents.to_i,
      settled_at: Time.now.utc }
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
    { psp_reference: "stub_pi_count", settled_amount_cents: cart_mandate.total_amount_cents.to_i,
      settled_at: Time.now.utc }
  end

  def setup_required?(*) = false
end

puts "\n== (a) POSITIVE CONTROL: a booking nobody paid for reads `unpaid` =="

unpaid = reserve!
unpaid_id = unpaid["booking_id"]
check(payment_state(unpaid_id) == "unpaid",
      "an untouched booking publishes payment_state=unpaid — the one answer that makes a fresh chain correct")

unpaid_refusal = verb_error(Kiosk::Server::Actions, "confirm_booking", booking_id: unpaid_id)
check(unpaid_refusal && unpaid_refusal.message.to_s.include?("no settlement for this booking"),
      "confirm_booking on it refuses with the flat «no settlement» — correct HERE, because nothing was " \
      "ever charged (got #{unpaid_refusal&.message.inspect})")

puts "\n== (b) IN FLIGHT: capture started, outcome unknown =="

inflight    = reserve!
inflight_id = inflight["booking_id"]
blocking    = BlockingPsp.new
provider    = ValidatingBookingProvider.new(blocking, currency: "eur")

pay_thread = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    provider.capture(cart_for(inflight_id, id: "cart-inflight"))
  end
end

claimed = wait_until { booking_payment_status(inflight_id) == Booking::PAYING }
check(claimed, "the pay CLAIMED the booking (payment_status → paying) before the capture")
check(settlements_for(inflight_id).zero?, "no settlement row exists for it — the capture has not returned")

state_inflight = payment_state(inflight_id)
check(state_inflight == "pending",
      "my_bookings publishes payment_state=pending while the capture is outstanding (got #{state_inflight.inspect})")
check(state_inflight != "unpaid",
      "my_bookings does NOT publish `unpaid` for a booking whose capture may already have taken the money")

refusal      = verb_error(Kiosk::Server::Actions, "confirm_booking", booking_id: inflight_id)
refusal_text = refusal&.message.to_s
check(refusal_text.include?("in progress"),
      "confirm_booking names the outstanding capture instead of answering «no settlement» " \
      "(#{refusal_text[0, 120].inspect})")
check(!refusal_text.include?("no settlement for this booking"),
      "confirm_booking does NOT answer «no settlement for this booking» about an in-flight charge")

puts "\n== (c) PHASE-3 WINDOW: capture RETURNED, settlement row not yet written =="

blocking.release!
ActiveSupport::Dependencies.interlock.permit_concurrent_loads { pay_thread.join }

check(settlements_for(inflight_id).zero?,
      "still no settlement row — the engine's phase 3 has not run (this IS the window)")
check(booking_payment_status(inflight_id) == Booking::PAID,
      "the cashier flipped the booking to `paid` the instant the capture returned")

state_window = payment_state(inflight_id)
check(state_window == "paid",
      "my_bookings publishes payment_state=paid on the CAPTURE alone, with zero settlement rows " \
      "(got #{state_window.inspect})")

confirmed = call_verb(Kiosk::Server::Actions, "confirm_booking", booking_id: inflight_id)
check(confirmed["status"] == "confirmed",
      "confirm_booking succeeds on the capture-anchored witness alone, no settlement row required")

puts "\n== (d) AT MOST ONCE: N racing /pay for one booking =="

raced    = reserve!
raced_id = raced["booking_id"]
counting = CountingPsp.new
racer    = ValidatingBookingProvider.new(counting, currency: "eur")

# One racer per SPARE pooled connection (the main thread holds one), capped at
# five. Sized from the pool rather than hardcoded so the script is honest when
# run without `RAILS_MAX_THREADS` — a racer that cannot get a connection proves
# nothing about serialization, it just times out.
RACERS = [5, ActiveRecord::Base.connection_pool.size - 1].min
abort "pool too small to race (#{ActiveRecord::Base.connection_pool.size})" if RACERS < 2

outcomes = RACERS.times.map do |i|
  Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do
      racer.capture(cart_for(raced_id, id: "cart-race-#{i}"))
      :captured
    rescue Kiosk::Server::Errors::Base
      :refused
    end
  end
end
outcomes = ActiveSupport::Dependencies.interlock.permit_concurrent_loads { outcomes.map(&:value) }

check(counting.count == 1,
      "exactly ONE of #{RACERS} racing pays reached the PSP (got #{counting.count})")
check(outcomes.count(:captured) == 1,
      "exactly ONE caller was told it captured; the other #{outcomes.count(:refused)} were refused before any charge")
check(payment_state(raced_id) == "paid", "the raced booking ends `paid`, once")

puts "\n== (e) TRANSCRIPT: `unpaid` was published only for the never-charged booking =="

OBSERVED.each do |booking_id, states|
  never_charged = booking_id == unpaid_id
  bad = states.select { |s| s == "unpaid" }
  check(never_charged || bad.empty?,
        "booking #{booking_id} never read `unpaid` after a capture was claimed for it (saw #{states.inspect})")
end

if FAILURES.empty?
  puts "\n  All capture-window assertions PASSED."
  exit 0
else
  puts "\n  FAILED assertions:"
  FAILURES.each { |f| puts "    - #{f}" }
  exit 1
end
