# frozen_string_literal: true

# Kiosk PoW end-to-end driver (equihash).
#
# Proves the full PoW challenge-response loop using the REAL shipped Python
# solver (kiosk-pow-equihash/solve.py). Steps:
#
#   1. Register an agent (registration is PoW-gated too; equihash_register
#      solves it transparently before returning).
#   2. GET /kiosk/availability?party_size=2 → expect HTTP 402 (pow_required).
#   3. Extract the challenge(s); shell out to solve.py → {indices, header_nonce}.
#   4. Re-GET the SAME URL with the Kiosk-PoW header: [{challenge, nonce}] → 200
#      + a bare array of open slots.
#   5. Submit a deliberately wrong nonce against a fresh challenge → expect
#      HTTP 403 (forbidden / invalid proof); assert on_bad_proof incremented
#      FOR THIS IDENTITY, and that a second, innocent identity's count stayed 0
#      (K-498 — the counter is per-identity, not one shared tally).
#
# THE 0.4 WIRE. `availability` is a QUERY, so it is `GET <endpoint>/availability`
# with its arguments in the query string — there is no `name` field and no
# `POST /kiosk/query`. A success body IS the result (a bare array here) and a
# 402 is an RFC 9457 problem document whose `code` and `challenges` are
# TOP-LEVEL members.
#
# Reservation-scalping is the abuse this prices at the door: PoW makes a
# script that mass-probes prime-time availability pay a metered toll per query.
#
# Prints ONE JSON line on stdout; non-zero exit on any assertion failure.
#
# Usage (invoked by rake demo:pow — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3002 KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby script/pow_flow.rb
#
# Requirements:
#   - The server must be running with KIOSK_POW_DEMO=1.
#   - python3 with numpy: pip install numpy

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

# The TOY counter the demo initializer's on_bad_proof writes (K-498):
# PER-IDENTITY in sqlite (one abuser's rejections never appear in anyone
# else's count), but still truncated at boot, no TTL, and read by nothing but
# this driver. It exists so step 5 below can assert the server counted the
# rejected proof against THIS identity and nobody else's — it is NOT the
# decayed, durable bad_proof_count a real provider needs.
require_relative "../app/services/bad_proof_counter"
# The path is OWNED by `rake demo:pow`, which exports it to the server it
# spawns and to this driver (K-711). No default on purpose: this used to be a
# second hand-typed literal, and a drift between the two copies opened an empty
# sqlite here, read 0 for every count, and reported the zeros as a pass. A
# KeyError is the only honest answer when nobody told this process where to look.
BAD_PROOF_DB = ENV.fetch("KIOSK_BAD_PROOF_DB")

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

# ── Step 1: register an agent (register PoW solved transparently) ────────────

_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
token    = reg.fetch("access_token")
agent_id = reg.fetch("agent_id")

# A second, INNOCENT identity (K-498): it registers and never submits a bad
# proof, so its per-identity count must still be 0 after this flow's wrong
# nonce lands on the first identity's tally.
_key2, reg2 = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
other_agent_id = reg2.fetch("agent_id")

# The request we prove. §3.4's fingerprint is
# `SHA256("<METHOD> <verb>\n<canonical args>")` — the HTTP method, the verb name
# as it appears in the PATH, and the canonical JSON of the arguments — so an
# identical retry means the same method, the same path AND the same query
# string. Every call below goes through `availability_once`, which builds all
# three from these two constants, so no retry can drift from the challenged
# request. The proof rides in the `Kiosk-PoW` header, never in the request.
QUERY_URL   = "#{SERVER}/kiosk/availability"
QUERY_ARGS  = { party_size: 2 }
AUTH_HEADER = { "Authorization" => "Bearer #{token}" }

# One availability call, optionally carrying proof(s). Identical method, path
# and query string every time — only the header differs.
def availability_once(proofs = nil)
  headers = proofs ? AUTH_HEADER.merge("Kiosk-PoW" => JSON.generate(proofs)) : AUTH_HEADER
  get_json(QUERY_URL, QUERY_ARGS, headers)
end

# ── Step 2: initial POST → expect 402 pow_required ─────────────────────────

rc_challenge, resp_challenge = availability_once
unless rc_challenge == 402
  abort "expected HTTP 402 (pow_required), got #{rc_challenge}: #{JSON.generate(resp_challenge)}"
end
unless resp_challenge["code"] == "pow_required"
  abort "expected top-level code == 'pow_required', got: #{JSON.generate(resp_challenge)}"
end
challenges = resp_challenge["challenges"]
abort "no challenges[] in 402 response" unless challenges.is_a?(Array) && challenges.any?

# ── Step 3: solve every challenge with the real shipped Python solver ───────

proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }

# ── Step 5 (negative — before spending): wrong nonce → 403 ─────────────────

rc_neg_issue, resp_neg_issue = availability_once
abort "expected fresh 402 for negative test, got #{rc_neg_issue}" unless rc_neg_issue == 402
challenge_neg = resp_neg_issue["challenges"].first
# A wrong nonce: right shape (distinct indices) but not a Wagner solution.
bad_nonce = { "indices" => (1..(proofs.first[:nonce]["indices"].length)).to_a, "header_nonce" => 0 }
# PoW proof(s) ride in the Kiosk-PoW request header as raw JSON (ADR-0022), not
# in the request — the method, path and query string stay identical so the
# challenge fingerprint matches.
rc_wrong, resp_wrong = availability_once([{ challenge: challenge_neg, nonce: bad_nonce }])
unless rc_wrong == 403
  abort "expected HTTP 403 for wrong nonce, got #{rc_wrong}: #{JSON.generate(resp_wrong)}"
end
# PER-IDENTITY (K-498): the offender's count moved, the innocent identity's
# did not — one bad client must not make everyone else suffer.
bad_proof_count = BadProofCounter.count(BAD_PROOF_DB, agent_id)
unless bad_proof_count >= 1
  abort "expected bad_proof_count >= 1 for the offending identity after wrong nonce, got #{bad_proof_count}"
end
other_bad_proof_count = BadProofCounter.count(BAD_PROOF_DB, other_agent_id)
unless other_bad_proof_count.zero?
  abort "expected bad_proof_count == 0 for the innocent identity, got #{other_bad_proof_count} — the counter is not per-identity (K-498)"
end

# ── Step 4: re-POST with correct proof(s) → expect 200 served ──────────────

rc_served, resp_served = availability_once(proofs)
# A non-paginating query answers a BARE JSON ARRAY; the `{rows: […]}` envelope
# was retired at the cutover.
rows   = rc_served == 200 ? Array(resp_served) : []
served = rc_served == 200 && rows.any?
unless served
  abort "expected HTTP 200 + rows after solve, got #{rc_served}: #{JSON.generate(resp_served)}"
end

# ── Output one JSON line ────────────────────────────────────────────────────

puts JSON.generate(
  http_challenge:          rc_challenge,
  http_served_after_solve: rc_served,
  http_wrong_nonce:        rc_wrong,
  served:                  served,
  proofs_solved:           proofs.size,
  bad_proof_count:         bad_proof_count,
  other_bad_proof_count:   other_bad_proof_count,
  availability_rows:       rows.size,
)
