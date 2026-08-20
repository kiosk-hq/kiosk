# frozen_string_literal: true

# Kiosk reputation end-to-end driver (anti-scalping — trust earned by booking).
#
# Demonstrates the full "PoW cost drops as a real booking history accrues"
# lifecycle using the shipped RateAndReputation policy with a real
# confirmed-bookings lookup. Escalation is by PROOF COUNT (N×PoW), not a
# difficulty dial:
#
#   0 confirmed bookings → 402 with N=2 equihash challenges (unproven principal)
#   1 confirmed booking  → 402 with N=1 challenge (cheaper — a booking earned relief)
#   2 confirmed bookings → 200 served directly, no challenge (proven → free pass)
#
# This is the anti-reservation-scalping mechanic: a fresh / low-reputation
# agent pays escalating PoW to probe prime-time availability; a scalper renting
# fresh identities pays and pays, while a returning diner earns relief.
#
# Steps:
#   1. Register a fresh principal.
#   2. GET /kiosk/availability → 402 (n0 proofs, unproven). Solve, served.
#   3. Make booking 1: POST /kiosk/book_table — PoW-gated at n0.
#   4. GET /kiosk/availability → 402 (n1 proofs). Solve, served. Assert n1 < n0.
#   5. Make booking 2 (same flow).
#   6. GET /kiosk/availability → 200 directly (free pass, proven). Assert no
#      challenge.
#   7. Emit ONE JSON line with the proof-count curve.
#
# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the query string; an action is `POST <endpoint>/<action-name>` with them as
# the JSON body. There is no `name` field, no /query or /run endpoint and no
# response envelope: a non-paginating query answers a BARE ARRAY, an action its
# own object, and a 402 is an RFC 9457 problem document whose `code` and
# `challenges` are TOP-LEVEL members.
#
# Usage (invoked by rake demo:reputation — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3104 \
#   KIOSK_ISSUER=http://127.0.0.1:3104 \
#   bundle exec ruby script/reputation_flow.rb
#
# Requirements:
#   - The server must be running with KIOSK_POW_REPUTATION_DEMO=1.
#   - python3 with numpy: pip install numpy

require "date"
require "json"
require "net/http"
require "uri"
require "openssl"
require "open3"
require "securerandom"
require "jwt"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# equihash_solve / equihash_register come from the shared helper; the solver
# location is Kiosk::Pow::Equihash.solver_path, owned by the gem (K-627).
require_relative "equihash_register"

# ── Shared helpers ─────────────────────────────────────────────────────────

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, params = {}, headers = {})
  uri = URI(url)
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Execute one wire verb with automatic PoW handling.
#
# If the server issues a 402, solves EVERY challenge in the problem document's
# top-level `challenges` with solve.py and re-sends the IDENTICAL request with
# the proof(s) in the Kiosk-PoW header. Returns [rc, resp, n] where n is the
# number of proofs solved (nil = no challenge — free pass). The proof count is
# this protocol's difficulty measure (N×PoW).
#
# §3.4's fingerprint is `SHA256("<METHOD> <verb>\n<canonical args>")`, so "the
# same request" now means the same METHOD and the same PATH SEGMENT as well as
# the same arguments. One `send_it` lambda builds every attempt from the same
# three, which is what makes the retry provably identical to the challenged
# call rather than merely similar.
#
# @param kind [Symbol] :query (GET, args in the query string) or :action (POST,
#   args as the JSON body) — the two halves of the per-verb wire
# @param verb [String] the registered verb name; it IS the path segment
def exec_with_pow(kind, verb, args, token)
  headers = { "Authorization" => "Bearer #{token}" }
  url     = "#{SERVER}/kiosk/#{verb}"
  send_it = lambda do |extra|
    kind == :query ? get_json(url, args, headers.merge(extra)) : post_json(url, args, headers.merge(extra))
  end

  rc, resp = send_it.call({})

  if rc == 402
    challenges = resp["challenges"]
    abort "missing challenges[] in 402 for #{verb}" unless challenges.is_a?(Array) && challenges.any?
    proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }

    # The solved proof(s) ride in the Kiosk-PoW request header as raw JSON
    # (ADR-0022) — method, path, query string and body are unchanged, so the
    # request_fingerprint the challenge binds to still matches.
    rc, resp = send_it.call("Kiosk-PoW" => JSON.generate(proofs))
    [rc, resp, proofs.size]
  else
    [rc, resp, nil]
  end
end

# Find an open (restaurant, table, seating) row for a party across the
# aggregator, excluding any [restaurant_table_id, seating_at] pairs.
# Availability itself is PoW-gated, so this goes through exec_with_pow.
def find_open_slot(party, token, exclude)
  rc, resp, _n = exec_with_pow(:query, "availability", { party_size: party }, token)
  abort "availability failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  rows = Array(resp).reject { |r| exclude.include?([r["restaurant_table_id"], r["seating_at"]]) }
  slot = rows.first
  abort "no open table for party #{party} (excluding #{exclude.inspect})" unless slot
  slot
end

# Execute one full booking: POST /kiosk/book_table, PoW-gated. Returns the
# claimed [restaurant_table_id, seating_at] pair (so the caller can avoid
# double-booking it) and booking_id.
def make_booking(party, token, taken)
  slot = find_open_slot(party, token, taken)
  rc, resp, _ = exec_with_pow(:action, "book_table",
    { restaurant_id: slot.fetch("restaurant_id"),
      restaurant_table_id: slot.fetch("restaurant_table_id"),
      date: slot.fetch("seating_date"), time: slot.fetch("seating_time"),
      party_size: party }, token)
  abort "book_table failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  booking_id = resp["booking_id"]
  abort "book_table returned no booking_id" if booking_id.to_s.empty?
  [[slot.fetch("restaurant_table_id"), slot.fetch("seating_at")], booking_id]
end

# ── Step 1: register a fresh principal (register PoW solved transparently) ───

_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)

token = reg.fetch("access_token")

taken = []
QUERY_ARGS = { party_size: 2 }

# ── Step 2: query with 0 bookings → 402 (n0 proofs, unproven) → solve → 200 ─

$stderr.puts "  [rep] Step 2: query availability (0 bookings) — expect 402 + challenges"
rc, resp, n0 = exec_with_pow(:query, "availability", QUERY_ARGS, token)
abort "expected 200 after solve (0 bookings), got #{rc}: #{JSON.generate(resp)}" unless rc == 200
abort "n0 must be non-nil — unproven principal must have received a challenge" if n0.nil?

$stderr.puts "  [rep] n0=#{n0} proofs (unproven, 0 bookings). #{Array(resp).size} open slots served after solve."

# ── Step 3: booking 1 ──────────────────────────────────────────────────────

$stderr.puts "  [rep] Step 3: making booking 1 (book_table, PoW-gated at n0=#{n0})"
t1, b1 = make_booking(2, token, taken)
taken << t1
$stderr.puts "  [rep] booking 1 confirmed (booking_id=#{b1}, slot=#{t1})"

# ── Step 4: query with 1 booking → 402 (n1 < n0) → solve → 200 ─────────────

$stderr.puts "  [rep] Step 4: query (1 booking) — expect 402 with fewer proofs"
rc, resp, n1 = exec_with_pow(:query, "availability", QUERY_ARGS, token)
abort "expected 200 after solve (1 booking), got #{rc}: #{JSON.generate(resp)}" unless rc == 200
abort "n1 must be non-nil — 1 booking is not yet proven" if n1.nil?
abort "expected proof count to drop after a booking: n1=#{n1} not < n0=#{n0}" unless n1 < n0

$stderr.puts "  [rep] n1=#{n1} proofs (1 booking). Cost dropped: #{n0} → #{n1} proofs."

# ── Step 5: booking 2 ──────────────────────────────────────────────────────

$stderr.puts "  [rep] Step 5: making booking 2 (book_table, PoW-gated at n1=#{n1})"
t2, b2 = make_booking(2, token, taken)
taken << t2
$stderr.puts "  [rep] booking 2 confirmed (booking_id=#{b2}, slot=#{t2})"

# ── Step 6: query with 2 bookings → 200 directly (proven — free pass) ──────

$stderr.puts "  [rep] Step 6: query (2 bookings) — expect 200 with NO challenge (free pass)"
rc2, resp2, n2 = exec_with_pow(:query, "availability", QUERY_ARGS, token)
served_after_2 = rc2 == 200

unless served_after_2
  abort "expected 200 free pass after 2 bookings, got #{rc2}: #{JSON.generate(resp2)}"
end
unless n2.nil?
  abort "expected no challenge (n2=nil) after 2 bookings — principal must be proven. Got n2=#{n2}"
end

$stderr.puts "  [rep] served without challenge! Proven principal — free pass confirmed."

# ── Step 7: emit ONE JSON line ─────────────────────────────────────────────

puts JSON.generate(
  proofs_unproven:          n0,
  proofs_after_1_booking:   n1,
  served_after_2_bookings:  served_after_2,
  challenge_after_2:        n2,
)
