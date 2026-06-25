# frozen_string_literal: true

# Kiosk PoW end-to-end driver (R2 Task 4).
#
# Proves the full PoW challenge-response loop using the REAL shipped Python
# solver (kiosk-pow/solve.py).  Steps:
#
#   1. Register an agent (no PoW on registration).
#   2. POST query menu_by_restaurant → expect HTTP 402 (pow_required).
#   3. Extract the challenge; shell out to solve.py → nonce.
#   4. Re-POST the SAME query + pow: {challenge, nonce} → expect HTTP 200 + rows.
#   5. Submit a deliberately wrong nonce against a fresh challenge → expect
#      HTTP 403 (forbidden / invalid proof); assert on_bad_proof counter
#      incremented.
#
# Prints ONE JSON line on stdout; non-zero exit on any assertion failure.
#
# Usage (invoked by rake demo:pow — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3002 \
#   KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby pow_flow.rb
#
# Requirements:
#   - The server must be running with KIOSK_POW_DEMO=1.
#   - python3 with argon2-cffi: pip install argon2-cffi

require "json"
require "net/http"
require "uri"
require "openssl"
require "open3"
require "securerandom"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
SOLVE_PY = File.expand_path("../kiosk-pow/solve.py", __dir__)

BAD_PROOF_FILE = "/tmp/kiosk-foodelivery-bad-proof.count"

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Step 1: register an agent ───────────────────────────────────────────────

key = OpenSSL::PKey::RSA.generate(2048)
rc, reg = post_json(
  "#{SERVER}/kiosk/agents/register",
  { name: "pow-agent-#{SecureRandom.hex(4)}", public_key: key.public_key.to_pem, role: "customer" },
)
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201

token = reg.fetch("access_token")

# The request we will prove.  Identical body is sent in all retry steps so
# the server computes the same request_fingerprint.
QUERY_COMMAND = "query"
QUERY_BODY    = { name: "menu_by_restaurant", restaurant: "Mamma Pizza" }
AUTH_HEADER   = { "Authorization" => "Bearer #{token}" }

# ── Step 2: initial POST → expect 402 pow_required ─────────────────────────

rc_challenge, resp_challenge = post_json(
  "#{SERVER}/kiosk/exec",
  { command: QUERY_COMMAND, body: QUERY_BODY },
  AUTH_HEADER,
)

unless rc_challenge == 402
  abort "expected HTTP 402 (pow_required), got #{rc_challenge}: #{JSON.generate(resp_challenge)}"
end
unless resp_challenge.dig("error", "code") == "pow_required"
  abort "expected error.code == 'pow_required', got: #{JSON.generate(resp_challenge)}"
end

challenge = resp_challenge.dig("error", "challenge")
abort "no challenge object in 402 response" unless challenge

# ── Step 3: solve with the real shipped Python solver ───────────────────────
#
# solve.py accepts the challenge as its first argument (reads challenge["salt"]
# and challenge["params"]; extra fields like id/alg/exp/sig are ignored).
# We pass the full challenge object so no field extraction is needed.

challenge_json = JSON.generate(challenge)
solve_out, status = Open3.capture2("python3", SOLVE_PY, challenge_json)
abort "solve.py exited non-zero: #{solve_out}" unless status.success?

begin
  nonce = JSON.parse(solve_out).fetch("nonce")
rescue KeyError, JSON::ParserError => e
  abort "solve.py output not parseable as {nonce:}: #{e.message}\nOutput: #{solve_out}"
end

# ── Step 5 (negative — done BEFORE spending the challenge): wrong nonce ─────
#
# Issue a FRESH challenge first (the initial challenge is not spent yet, but
# using the same one for the negative test and then immediately the positive
# test avoids any ordering dependency).  A fresh 402 gives us an independent
# challenge for the wrong-nonce test so the solve+serve step is unaffected.

rc_neg_issue, resp_neg_issue = post_json(
  "#{SERVER}/kiosk/exec",
  { command: QUERY_COMMAND, body: QUERY_BODY },
  AUTH_HEADER,
)
abort "expected fresh 402 for negative test, got #{rc_neg_issue}" unless rc_neg_issue == 402
challenge_neg = resp_neg_issue.dig("error", "challenge")

# Submit a wrong nonce against the negative challenge.  "invalid-nonce" is
# not a decimal integer; Argon2id("invalid-nonce", ...) will not satisfy d=5
# zero-bits with overwhelming probability.
rc_wrong, resp_wrong = post_json(
  "#{SERVER}/kiosk/exec",
  { command: QUERY_COMMAND, body: QUERY_BODY, pow: { challenge: challenge_neg, nonce: "invalid-nonce" } },
  AUTH_HEADER,
)

unless rc_wrong == 403
  abort "expected HTTP 403 for wrong nonce, got #{rc_wrong}: #{JSON.generate(resp_wrong)}"
end

# Read the server-side bad_proof_count (written by on_bad_proof to the
# counter file, which was reset to 0 on server startup).
bad_proof_count = File.read(BAD_PROOF_FILE).to_i rescue 0
unless bad_proof_count >= 1
  abort "expected bad_proof_count >= 1 after wrong nonce, got #{bad_proof_count}"
end

# ── Step 4: re-POST with correct proof → expect 200 served ─────────────────

rc_served, resp_served = post_json(
  "#{SERVER}/kiosk/exec",
  { command: QUERY_COMMAND, body: QUERY_BODY, pow: { challenge: challenge, nonce: nonce } },
  AUTH_HEADER,
)

rows   = resp_served.fetch("rows", [])
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
  nonce:                   nonce,
  bad_proof_count:         bad_proof_count,
  menu_rows:               rows.size,
)
