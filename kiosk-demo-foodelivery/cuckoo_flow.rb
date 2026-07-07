# frozen_string_literal: true

# Kiosk Cuckatoo PoW end-to-end driver (R2 Task T3).
#
# TOY MECHANISM DEMO — proofsize 12 at edgebits 10; NOT production difficulty.
#
# Proves the full Cuckatoo PoW challenge-response loop using the REAL shipped
# Python solver (kiosk-pow-cuckoo/solve_cuckoo.py).  Steps:
#
#   1. Register an agent (no PoW on registration).
#   2. POST query menu_by_restaurant → expect HTTP 402 (pow_required) with
#      alg=cuckatoo.
#   3. Extract the challenge; shell out to solve_cuckoo.py (under the safety
#      wrapper: 512 MB cap + 30 s timeout + low priority) → {header_nonce, cycle}.
#   4. Re-POST the SAME query + pow: {challenge, nonce: {header_nonce, cycle}}
#      → expect HTTP 200 + rows.
#   5. Submit a deliberately wrong proof (bad cycle) against a fresh challenge
#      → expect HTTP 403 (forbidden / invalid proof); assert on_bad_proof
#      counter incremented.
#
# The composite nonce {header_nonce, cycle} is the wire format for Cuckatoo
# proofs — unlike Argon2id which uses a scalar nonce. kiosk-reputation passes
# it through unchanged to the backend's .verify call.
#
# Prints ONE JSON line on stdout; non-zero exit on any assertion failure.
#
# Usage (invoked by rake demo:cuckoo — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3002 \
#   KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby cuckoo_flow.rb
#
# Requirements:
#   - The server must be running with KIOSK_POW_CUCKOO_DEMO=1.
#   - python3 with numpy: pip install numpy

require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "open3"
require "securerandom"
require "shellwords"

SERVER       = ENV.fetch("SERVER_URL")
ISSUER       = ENV.fetch("KIOSK_ISSUER")
SOLVE_PY     = File.expand_path("../kiosk-pow-cuckoo/solve_cuckoo.py", __dir__)
CUCKOO_BAD_PROOF_FILE = "/tmp/kiosk-foodelivery-cuckoo-bad-proof.count"

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

# ── Step 1: register an agent ───────────────────────────────────────────────

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

QUERY_COMMAND = "query"
QUERY_BODY    = { name: "menu_by_restaurant", restaurant: "Mamma Pizza" }
AUTH_HEADER   = { "Authorization" => "Bearer #{token}" }

# ── Step 2: initial POST → expect 402 pow_required (alg=cuckatoo) ──────────

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

# Confirm the challenge is Cuckatoo (alg=cuckatoo).
alg = challenge["alg"]
unless alg == "cuckatoo"
  abort "expected alg='cuckatoo', got #{alg.inspect}. Is KIOSK_POW_CUCKOO_DEMO=1 set?"
end

# ── Step 3: solve with solve_cuckoo.py (real solver, under safety wrapper) ──
#
# TOY MECHANISM DEMO — proofsize 12 at edgebits 10; NOT production difficulty.
# Safety wrapper: KIOSK_POW_MAX_BYTES=536870912 (512 MB cap) + 30 s timeout +
# nice -n 19 (low priority). The solver's own _enforce_memory_budget guard also
# refuses oversized edgebits before allocating.

challenge_json = JSON.generate(challenge)

abort "solve_cuckoo.py not found at #{SOLVE_PY}" unless File.exist?(SOLVE_PY)

# Safety wrapper: 512 MB cap + 30 s timeout + low priority.
# Shellwords.shellescape ensures the JSON is properly quoted even with spaces/braces.
safe_solve_cmd = "KIOSK_POW_MAX_BYTES=536870912 timeout 30 nice -n 19 " \
                 "python3 #{Shellwords.shellescape(SOLVE_PY)} " \
                 "#{Shellwords.shellescape(challenge_json)}"

solve_out, status = Open3.capture2("sh", "-c", safe_solve_cmd)
unless status.success?
  abort "solve_cuckoo.py exited non-zero (#{status.exitstatus}): #{solve_out}"
end

begin
  proof = JSON.parse(solve_out.strip)
  header_nonce = proof.fetch("header_nonce")
  cycle        = proof.fetch("cycle")
rescue KeyError, JSON::ParserError => e
  abort "solve_cuckoo.py output not parseable as {header_nonce:, cycle:}: #{e.message}\nOutput: #{solve_out}"
end

# The Cuckatoo nonce is a composite object — NOT a scalar string.
# kiosk-reputation forwards it unchanged to Kiosk::Pow::Cuckoo.verify.
nonce = { header_nonce: header_nonce, cycle: cycle }

# ── Step 5 (negative — done BEFORE spending the challenge): wrong proof ──────
#
# Issue a fresh challenge for the negative test.  A wrong proof = valid-looking
# nonce structure but a cycle that does NOT satisfy the Cuckatoo verifier.

rc_neg_issue, resp_neg_issue = post_json(
  "#{SERVER}/kiosk/exec",
  { command: QUERY_COMMAND, body: QUERY_BODY },
  AUTH_HEADER,
)
abort "expected fresh 402 for negative test, got #{rc_neg_issue}" unless rc_neg_issue == 402
challenge_neg = resp_neg_issue.dig("error", "challenge")

# Bad cycle: take the real cycle but corrupt the first edge (±1).
# Even one wrong edge makes the Cuckatoo verifier reject the proof.
bad_cycle  = cycle.dup
bad_cycle[0] = bad_cycle[0] == 0 ? bad_cycle[0] + 1 : bad_cycle[0] - 1
bad_nonce  = { header_nonce: header_nonce, cycle: bad_cycle.sort }

rc_wrong, resp_wrong = post_json(
  "#{SERVER}/kiosk/exec",
  { command: QUERY_COMMAND, body: QUERY_BODY, pow: { challenge: challenge_neg, nonce: bad_nonce } },
  AUTH_HEADER,
)
unless rc_wrong == 403
  abort "expected HTTP 403 for wrong Cuckatoo proof, got #{rc_wrong}: #{JSON.generate(resp_wrong)}"
end

bad_proof_count = File.read(CUCKOO_BAD_PROOF_FILE).to_i rescue 0
unless bad_proof_count >= 1
  abort "expected cuckoo bad_proof_count >= 1 after wrong proof, got #{bad_proof_count}"
end

# ── Step 4: re-POST with correct Cuckatoo proof → expect 200 served ─────────

rc_served, resp_served = post_json(
  "#{SERVER}/kiosk/exec",
  { command: QUERY_COMMAND, body: QUERY_BODY, pow: { challenge: challenge, nonce: nonce } },
  AUTH_HEADER,
)

rows   = resp_served.fetch("rows", [])
served = rc_served == 200 && rows.any?

unless served
  abort "expected HTTP 200 + rows after Cuckatoo solve, got #{rc_served}: #{JSON.generate(resp_served)}"
end

# ── Output one JSON line ─────────────────────────────────────────────────────

puts JSON.generate(
  alg:                     alg,
  http_challenge:          rc_challenge,
  http_served_after_solve: rc_served,
  http_wrong_proof:        rc_wrong,
  served:                  served,
  header_nonce:            header_nonce,
  cycle_length:            cycle.length,
  bad_proof_count:         bad_proof_count,
  menu_rows:               rows.size,
)
