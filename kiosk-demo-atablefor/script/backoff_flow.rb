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
#   1. Register a fresh agent (registration is PoW-gated too; equihash_register
#      solves it transparently before returning).
#   2. GET /kiosk/availability?party_size=2 → expect HTTP 402 (pow_required) —
#      no grant yet.
#   3. Solve the challenge(s) with solve.py, resubmit the SAME request →
#      expect HTTP 200 (proof verified; the gate's on_proof_verified sets the
#      grant to 3).
#   4. The NEXT 3 identical requests are served WITHOUT a challenge (HTTP 200,
#      no 402) — the grant is consumed one per call.
#   5. The 4th follow-up request is challenged again (HTTP 402) — the grant is
#      exhausted, so the toll returns.
#
# THE 0.4 WIRE. `availability` is a QUERY, so it is `GET <endpoint>/availability`
# with its arguments in the query string — there is no `name` field and no
# `POST /kiosk/query`. A 402 is an RFC 9457 problem document whose `code` and
# `challenges` are TOP-LEVEL members, and a served non-paginating query is a
# bare JSON array.
#
# Prints ONE JSON line on stdout; non-zero exit on any assertion failure.
#
# Usage (invoked by rake demo:backoff — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3106 KIOSK_ISSUER=http://127.0.0.1:3106 \
#   bundle exec ruby script/backoff_flow.rb
#
# Requirements:
#   - The server must be running with KIOSK_POW_BACKOFF_DEMO=3 — the value is
#     the free-call COUNT (not a boolean), and this flow asserts EXACTLY 3
#     free calls, so any other count fails the assertions below.
#   - python3 with numpy: pip install numpy

require "date"
require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "open3"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# equihash_solve / equihash_register come from the shared helper; the solver
# location is Kiosk::Pow::Equihash.solver_path, owned by the gem (K-627).
require_relative "equihash_register"

GRANT_COUNT = 3 # must match the Backoff policy's count: in config/initializers/kiosk.rb

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

# ── Step 1: register a fresh agent (register PoW solved transparently) ───────

_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
token = reg.fetch("access_token")

# The request we prove. The request fingerprint is
# `SHA256("<METHOD> <verb>\n<canonical args>")` — the HTTP method, the verb name
# as it appears in the PATH, and the canonical JSON of the arguments — so an
# identical retry means the same method, the same path AND the same query
# string. Every call below is built from these two constants by
# `availability_once`, so no retry can drift from the challenged request. The
# proof rides in the `Kiosk-PoW` header, never in the request.
QUERY_URL   = "#{SERVER}/kiosk/availability"
QUERY_ARGS  = { party_size: 2 }
AUTH_HEADER = { "Authorization" => "Bearer #{token}" }

# One availability call, optionally carrying proof(s). Identical method, path
# and query string every time — only the header differs.
def availability_once(proofs = nil)
  headers = proofs ? AUTH_HEADER.merge("Kiosk-PoW" => JSON.generate(proofs)) : AUTH_HEADER
  get_json(QUERY_URL, QUERY_ARGS, headers)
end

# Perform one availability query. Returns the HTTP status only (no PoW handling).
def query_once
  rc, _resp = availability_once
  rc
end

# ── Step 2: initial query → expect 402 (no grant yet) ───────────────────────

rc_first = query_once
abort "expected HTTP 402 (pow_required) on the first query, got #{rc_first}" unless rc_first == 402

# Re-issue to grab the challenge to solve (the first call above did not carry a
# proof; ask again to obtain fresh challenges).
rc_issue, resp_issue = availability_once
abort "expected 402 when issuing challenge, got #{rc_issue}" unless rc_issue == 402
challenges = resp_issue["challenges"]
abort "no challenges[] in 402 response" unless challenges.is_a?(Array) && challenges.any?

# ── Step 3: solve → resubmit → expect 200 (grant set to GRANT_COUNT) ────────

proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
# PoW proof(s) ride in the Kiosk-PoW request header as raw JSON (ADR-0022), not
# in the request — the method, path and query string stay identical so the
# challenge fingerprint matches.
rc_solved, resp_solved = availability_once(proofs)
# A non-paginating query answers a BARE JSON ARRAY; the `{rows: […]}` envelope
# was retired at the cutover.
rows = rc_solved == 200 ? Array(resp_solved) : []
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
