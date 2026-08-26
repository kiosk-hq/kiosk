# frozen_string_literal: true

# Standalone (no rails boot, no DB) unit spec for the order-reference shape
# check — the K-579 guard, `app/models/uuid_check.rb`. Run with:
#   bundle exec rake demo:cashier_spec   (or: ruby spec/cashier_order_ref_spec.rb)
#
# `UuidCheck` guards the three places an agent-supplied id reaches an `::uuid`
# cast: the cashier's cart reference (here), create_order's replace path and
# reschedule_delivery (both in config/initializers/kiosk.rb, so they need a
# booted app — `rake demo:race` drives those over the real DB). Before the guard
# a malformed value made Postgres raise InvalidTextRepresentation, which is not
# a Kiosk::Server::Errors::Base and so escaped the wire controller as an HTTP
# 500. This spec pins, without a database:
#   • a malformed reference → a clean 400 bad_request that echoes the value and
#     leaks no SQL / PG internals;
#   • the guard runs BEFORE any SQL — this whole file runs with ActiveRecord
#     never loaded, which is only possible if the check precedes the connection;
#   • the pre-existing 403 cashier rejections (wrong currency, not exactly one
#     order_id) are unchanged and still ordered ahead of the shape check;
#   • the accepted shape is exactly the one create_order hands out (every
#     SecureRandom.uuid, case-insensitively) and nothing looser;
#   • the guard is a GATE and not a formality (K-1061): with a stub `Order`
#     standing in for the persistence boundary, a canonical uuid ARRIVES there
#     (bound as `$1` in the claim UPDATE) and a malformed one never does. That
#     pair goes red if the UuidCheck call is deleted; the negative-only
#     assertion it replaced stayed green.
# This is the DB-free test seam for the fix (getgrocery ships no rspec).

require "securerandom"
require "kiosk/server/errors"

require_relative "../app/models/uuid_check"
require_relative "../app/services/validating_payment_provider"

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

Cart = Struct.new(:currency, :line_items, :user_id, :total_amount_cents, keyword_init: true)

CASHIER = ValidatingPaymentProvider.new(:no_psp_should_be_reached, currency: "eur")

# Capture the error `capture` raises (nil when it somehow raises nothing).
def error_from(cart)
  CASHIER.capture(cart)
  nil
rescue StandardError => e
  e
end

def eur_cart(refs)
  Cart.new(
    currency:           "eur",
    line_items:         refs.map { |r| { "order_id" => r } },
    user_id:            SecureRandom.uuid,
    total_amount_cents: 1000,
  )
end

# ── A malformed order_id is a clean 400, not a 500 ───────────────────────────
[
  "not-a-uuid",
  "'; DROP TABLE orders; --",
  "12345",
  "3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5",   # one hex digit short
  "3f0c1a2e4b5d6e7f8a9b0c1d2e3f4a5b",      # un-hyphenated (Postgres-legal, not canonical)
].each do |bad|
  e = error_from(eur_cart([bad]))
  assert(e.is_a?(Kiosk::Server::Errors::BadRequest),
         "malformed order_id #{bad.inspect} → BadRequest, got #{e.class}")
  next unless e.is_a?(Kiosk::Server::Errors::BadRequest)

  assert(e.http_status == 400 && e.code == "bad_request",
         "  … serialised as #{e.code}/#{e.http_status} (want bad_request/400)")
  assert(e.message.include?(bad.inspect),
         "  … names the value the agent sent: #{e.message}")

  wire = "#{e.message} #{e.hint}"
  leaks = ["::uuid", "PG::", "ActiveRecord", "22P02", "SELECT", "UPDATE", "invalid input syntax"]
         .select { |needle| wire.include?(needle) }
  assert(leaks.empty?, "  … leaks no SQL/PG internals to the wire (found #{leaks.inspect})")
  assert(!e.hint.to_s.empty?, "  … carries an actionable hint: #{e.hint}")
end

# ── The guard reaches no database ────────────────────────────────────────────
# Nothing above touched Postgres — ActiveRecord is not even loaded here — so the
# 400s above are proof the check precedes the connection and every ::uuid cast.
assert(!defined?(ActiveRecord::Base),
       "the shape check ran without ActiveRecord loaded (it precedes every ::uuid cast)")

# ── Pre-existing 403 rejections are unchanged and still ordered first ────────
wrong_currency = Cart.new(currency: "usd", line_items: [{ "order_id" => "not-a-uuid" }],
                          user_id: SecureRandom.uuid, total_amount_cents: 1000)
e = error_from(wrong_currency)
assert(e.is_a?(Kiosk::Server::Errors::Forbidden),
       "a non-EUR cart is still a 403 forbidden (currency check stays ahead of the shape check), got #{e.class}")

e = error_from(eur_cart([]))
assert(e.is_a?(Kiosk::Server::Errors::Forbidden),
       "a cart referencing NO order is still a 403 forbidden, got #{e.class}")

e = error_from(eur_cart([SecureRandom.uuid, SecureRandom.uuid]))
assert(e.is_a?(Kiosk::Server::Errors::Forbidden),
       "a cart referencing TWO orders is still a 403 forbidden, got #{e.class}")

# ── The accepted shape is exactly create_order's own ─────────────────────────
rejected = Array.new(50) { SecureRandom.uuid }.reject { |id| UuidCheck.valid?(id) }
assert(rejected.empty?,
       "UuidCheck accepts every SecureRandom.uuid (the shape create_order returns), " \
       "rejected #{rejected.inspect}")
assert(UuidCheck.valid?("3F0C1A2E-4B5D-6E7F-8A9B-0C1D2E3F4A5B"),
       "UuidCheck accepts an upper-case uuid")
assert(!UuidCheck.valid?(nil) && !UuidCheck.valid?(12_345) && !UuidCheck.valid?({ "a" => 1 }),
       "UuidCheck rejects non-String junk (nil / Integer / Hash) instead of raising")
assert(!UuidCheck.valid?(" #{SecureRandom.uuid} ") &&
       !UuidCheck.valid?("#{SecureRandom.uuid}\n#{SecureRandom.uuid}"),
       "UuidCheck anchors the whole string — padded and multi-line values are rejected")

# ── The guard is a GATE: what it accepts arrives, what it refuses never does ──
#
# Everything above ran with no persistence layer at all, so the accepted path
# had nowhere to ARRIVE and the only sayable thing about it was the negative
# "not a BadRequest" — which `nil`, any error raised BEFORE the guard, and a
# DELETED guard call all satisfy equally (K-1061). So plant the boundary: a
# stub `Order` in the provider's own namespace, occupying the seam the
# Rails-only constant occupies at runtime. It records the order_id bound into
# the claim UPDATE as `$1` and answers "no row claimed", which sends the
# provider down its order-not-found branch. It is not ActiveRecord, opens no
# connection and executes no SQL — and it is planted HERE, after the assertion
# above that the shape check ran with ActiveRecord never loaded.
class ValidatingPaymentProvider
  class Order
    PAYING = "paying"
    BOUND  = []

    class << self
      def reset! = BOUND.clear
      def lease_connection = self

      def exec_query(_sql, _name, binds)
        BOUND << binds.first
        [] # zero rows claimed
      end

      def where(**_conditions) = self
      def pick(_column)        = nil
    end
  end
end

canonical = SecureRandom.uuid
ValidatingPaymentProvider::Order.reset!
e = error_from(eur_cart([canonical]))
assert(ValidatingPaymentProvider::Order::BOUND == [canonical] &&
       !e.is_a?(Kiosk::Server::Errors::BadRequest),
       "a canonical uuid passes the guard and reaches the persistence layer — the claim " \
       "UPDATE bound it as $1 (#{ValidatingPaymentProvider::Order::BOUND.inspect}); the " \
       "refusal that comes back is the boundary's, not the guard's (#{e.class})")

ValidatingPaymentProvider::Order.reset!
e = error_from(eur_cart(["not-a-uuid"]))
assert(ValidatingPaymentProvider::Order::BOUND.empty? &&
       e.is_a?(Kiosk::Server::Errors::BadRequest),
       "… and a malformed one never reaches it: the guard refuses before the claim UPDATE " \
       "binds anything (bound #{ValidatingPaymentProvider::Order::BOUND.inspect}, " \
       "got #{e.class}) — delete the UuidCheck call and THIS assertion goes red")

if FAILURES.empty?
  puts "\ncashier order-ref K-579 spec: ALL PASS"
  exit 0
else
  puts "\ncashier order-ref K-579 spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
