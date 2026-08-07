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
#   2. POST query availability → 402 (n0 proofs, unproven). Solve, served.
#   3. Make booking 1: book_table (run) — PoW-gated at n0.
#   4. POST query → 402 (n1 proofs). Solve, served. Assert n1 < n0.
#   5. Make booking 2 (same flow).
#   6. POST query → 200 directly (free pass, proven). Assert no challenge.
#   7. Emit ONE JSON line with the proof-count curve.
#
# Usage (invoked by rake demo:reputation — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3004 \
#   KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby reputation_flow.rb
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

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
SOLVE_PY = File.expand_path("../kiosk-pow-equihash/solve.py", __dir__)

# ── Shared helpers ─────────────────────────────────────────────────────────

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, headers = {})
  uri = URI(url)
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Solve one equihash challenge with the shipped Python solver → proof nonce.
def solve_challenge(challenge)
  out, status = Open3.capture2("python3", SOLVE_PY, JSON.generate(challenge))
  abort "solve.py failed for challenge #{challenge["id"]}: #{out}" unless status.success?
  parsed = JSON.parse(out)
  abort "solve.py error: #{parsed["error"]}" if parsed.key?("error")
  { "indices" => parsed.fetch("indices"), "header_nonce" => parsed.fetch("header_nonce") }
end

# Execute a Kiosk verb with automatic PoW handling.
#
# If the server issues a 402, solves EVERY challenge in error.challenges[] with
# solve.py and re-sends the SAME body with the proof(s) in the Kiosk-PoW header.
# Returns [rc, resp, n] where n is the number of proofs solved (nil = no
# challenge — free pass). The proof count is this protocol's difficulty measure
# (N×PoW).
def exec_with_pow(command, body, token)
  headers = { "Authorization" => "Bearer #{token}" }
  path    = "#{SERVER}/kiosk/#{command}"  # REST verb endpoint (query/run)

  rc, resp = post_json(path, body, headers)

  if rc == 402
    challenges = resp.dig("error", "challenges")
    abort "missing challenges[] in 402 for #{command}" unless challenges.is_a?(Array) && challenges.any?
    proofs = challenges.map { |c| { challenge: c, nonce: solve_challenge(c) } }

    # Re-submit the IDENTICAL body; the solved proof(s) ride in the Kiosk-PoW
    # request header as raw JSON (ADR-0022) — the body stays byte-identical so
    # the request_fingerprint the challenge binds to still matches.
    rc, resp = post_json(path, body, headers.merge("Kiosk-PoW" => JSON.generate(proofs)))
    [rc, resp, proofs.size]
  else
    [rc, resp, nil]
  end
end

TOMORROW = (Date.today + 1).iso8601

# Find an open slot time for a party of `party` tomorrow, excluding any of
# `exclude_times`. Availability itself is PoW-gated, so this goes through
# exec_with_pow. Returns [time, proofs_solved].
def find_open_time(party, token, exclude_times)
  rc, resp, _n = exec_with_pow("query", { name: "availability", date: TOMORROW, party_size: party }, token)
  abort "availability failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  rows = (resp.fetch("rows", [])).reject { |r| exclude_times.include?(r["slot_time"]) }
  slot = rows.first
  abort "no open slot for party #{party} tomorrow (excluding #{exclude_times.inspect})" unless slot
  slot.fetch("slot_time")
end

# Execute one full booking: book_table (run), PoW-gated. Returns the slot_time
# used (so the caller can avoid double-booking it) and booking_id.
def make_booking(party, token, taken_times)
  time = find_open_time(party, token, taken_times)
  rc, resp, _ = exec_with_pow("run",
    { name: "book_table", date: TOMORROW, time: time, party_size: party }, token)
  abort "book_table failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  booking_id = resp.dig("value", "booking_id")
  abort "book_table returned no booking_id" if booking_id.to_s.empty?
  [time, booking_id]
end

# ── Step 1: register a fresh principal ─────────────────────────────────────

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
rc_ch, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode(
  { aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key, "RS256",
)
rc, reg = post_json(
  "#{SERVER}/kiosk/auth/register",
  { public_key: pem, signed: pop },
)
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201

token = reg.fetch("access_token")

taken = []
QUERY_BODY = { name: "availability", date: TOMORROW, party_size: 2 }

# ── Step 2: query with 0 bookings → 402 (n0 proofs, unproven) → solve → 200 ─

$stderr.puts "  [rep] Step 2: query availability (0 bookings) — expect 402 + challenges"
rc, resp, n0 = exec_with_pow("query", QUERY_BODY, token)
abort "expected 200 after solve (0 bookings), got #{rc}: #{JSON.generate(resp)}" unless rc == 200
abort "n0 must be non-nil — unproven principal must have received a challenge" if n0.nil?

$stderr.puts "  [rep] n0=#{n0} proofs (unproven, 0 bookings). #{resp.fetch('rows', []).size} open slots served after solve."

# ── Step 3: booking 1 ──────────────────────────────────────────────────────

$stderr.puts "  [rep] Step 3: making booking 1 (book_table, PoW-gated at n0=#{n0})"
t1, b1 = make_booking(2, token, taken)
taken << t1
$stderr.puts "  [rep] booking 1 confirmed (booking_id=#{b1}, slot=#{t1})"

# ── Step 4: query with 1 booking → 402 (n1 < n0) → solve → 200 ─────────────

$stderr.puts "  [rep] Step 4: query (1 booking) — expect 402 with fewer proofs"
rc, resp, n1 = exec_with_pow("query", QUERY_BODY, token)
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
rc2, resp2, n2 = exec_with_pow("query", QUERY_BODY, token)
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
