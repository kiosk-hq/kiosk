# frozen_string_literal: true

# Kiosk COUNT-BASED PoW backoff end-to-end driver (POW-RECENCY-GRACE).
#
# Proves the "solve once, next N calls free" mechanic against the shipped
# Kiosk::Reputation::Policies::Backoff (count: 3) over plain HTTP, using the REAL
# bundled Python solver (kiosk-pow-equihash/solve.py). The grant is a COUNT, not
# a time window — a window would let a bot flood thousands of requests inside it;
# a count caps exactly how many free calls one solve buys.
#
# Sequence (the load-bearing proof):
#   1. Register a fresh agent (no PoW on registration).
#   2. POST query availability → expect HTTP 402 (pow_required) — no grant yet.
#   3. Solve the challenge(s) with solve.py, resubmit the SAME query →
#      expect HTTP 200 (proof verified; the gate's on_proof_verified sets the
#      grant to 3).
#   4. The NEXT 3 identical requests are served WITHOUT a challenge (HTTP 200,
#      no 402) — the grant is consumed one per call.
#   5. The 4th follow-up request is challenged again (HTTP 402) — the grant is
#      exhausted, so the toll returns.
#
# Prints ONE JSON line on stdout; non-zero exit on any assertion failure.
#
# Usage (invoked by rake demo:backoff — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3002 KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby backoff_flow.rb
#
# Requirements:
#   - The server must be running with KIOSK_POW_BACKOFF_DEMO=1.
#   - python3 with numpy: pip install numpy

require "date"
require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "open3"
require "securerandom"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
SOLVE_PY = File.expand_path("../kiosk-pow-equihash/solve.py", __dir__)

GRANT_COUNT = 3 # must match the Backoff policy's count: in config/initializers/kiosk.rb

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
def solve(challenge)
  out, status = Open3.capture2("python3", SOLVE_PY, JSON.generate(challenge))
  abort "solve.py exited non-zero: #{out}" unless status.success?
  parsed = JSON.parse(out)
  abort "solve.py error: #{parsed["error"]}" if parsed.key?("error")
  { "indices" => parsed.fetch("indices"), "header_nonce" => parsed.fetch("header_nonce") }
end

# ── Step 1: register a fresh agent ──────────────────────────────────────────

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
rc_ch, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode(
  { aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key, "RS256",
)
rc, reg = post_json("#{SERVER}/kiosk/auth/register", { public_key: pem, signed: pop })
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
token = reg.fetch("access_token")

# The request we prove. The identical body is sent on every retry so the server
# computes the same request_fingerprint; the proof is a top-level `pow` sibling.
QUERY_BODY  = { name: "availability", date: (Date.today + 1).iso8601, party_size: 2 }
AUTH_HEADER = { "Authorization" => "Bearer #{token}" }

# Perform one availability query. Returns the HTTP status only (no PoW handling).
def query_once
  rc, _resp = post_json("#{SERVER}/kiosk/query", QUERY_BODY, AUTH_HEADER)
  rc
end

# ── Step 2: initial query → expect 402 (no grant yet) ───────────────────────

rc_first = query_once
abort "expected HTTP 402 (pow_required) on the first query, got #{rc_first}" unless rc_first == 402

# Re-issue to grab the challenge to solve (the first call above did not carry a
# proof; ask again to obtain fresh challenges).
rc_issue, resp_issue = post_json("#{SERVER}/kiosk/query", QUERY_BODY, AUTH_HEADER)
abort "expected 402 when issuing challenge, got #{rc_issue}" unless rc_issue == 402
challenges = resp_issue.dig("error", "challenges")
abort "no challenges[] in 402 response" unless challenges.is_a?(Array) && challenges.any?

# ── Step 3: solve → resubmit → expect 200 (grant set to GRANT_COUNT) ────────

proofs = challenges.map { |c| { challenge: c, nonce: solve(c) } }
rc_solved, resp_solved = post_json(
  "#{SERVER}/kiosk/query",
  QUERY_BODY.merge(pow: { proofs: proofs }),
  AUTH_HEADER,
)
rows = resp_solved.fetch("rows", [])
unless rc_solved == 200
  abort "expected HTTP 200 after solve, got #{rc_solved}: #{JSON.generate(resp_solved)}"
end

# ── Step 4: the next GRANT_COUNT requests are served WITHOUT a challenge ─────

free_statuses = Array.new(GRANT_COUNT) { query_once }
unless free_statuses.all?(200)
  abort "expected the next #{GRANT_COUNT} requests to be served (200, no challenge) after a solve; got #{free_statuses.inspect}"
end

# ── Step 5: the request after the grant is exhausted is challenged again ─────

rc_after = query_once
unless rc_after == 402
  abort "expected HTTP 402 once the grant of #{GRANT_COUNT} is exhausted, got #{rc_after}"
end

# ── Output one JSON line ────────────────────────────────────────────────────

puts JSON.generate(
  http_first_challenge:   rc_first,       # 402 (no grant yet)
  http_served_after_solve: rc_solved,     # 200 (proof verified → grant set)
  grant_count:            GRANT_COUNT,    # N free calls a solve buys
  free_call_statuses:     free_statuses,  # [200, 200, 200] — the grant consumed
  http_after_grant:       rc_after,       # 402 (grant exhausted → toll returns)
  availability_rows:      rows.size,
)
