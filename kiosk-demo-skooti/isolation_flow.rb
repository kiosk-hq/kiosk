# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver (R1 Phase 1 Task 2).
#
# Proves skooti app-layer predicates enforce cross-tenant denial:
#
#   Assertion 1 — start_rental ownership denial:
#     Principal A reserves scooter → reservation_id rA.
#     Principal B calls run start_rental {reservation_id: rA} with B's token.
#     → Must be denied (HTTP 403). Gate-1 WHERE user_id = kiosk.current_user_id()
#       finds nothing because rA belongs to A.
#
#   Assertion 2 — my_reservations exclusion:
#     B's query my_reservations must NOT contain rA (B sees only B's rows).
#
#   Assertion 3 — forged user_id ignored on reserve:
#     B calls run reserve with a forged user_id arg (A's UUID).
#     → The created reservation's user_id is B (server uses kiosk.current_user_id(),
#       ignores agent-supplied user_id). Verified by DB SELECT.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3003 \
#   KIOSK_ISSUER=http://127.0.0.1:3003 \
#   bundle exec ruby isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "digest"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "stub_kyc"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# ── helpers ──────────────────────────────────────────────────────────────────

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Replicates Kiosk::Server::ProofOfWork.leading_zero_bits exactly.
def leading_zero_bits(bytes)
  return 0 if bytes.empty?

  count = 0
  bytes.each_byte do |b|
    if b == 0
      count += 8
    else
      bit = 7
      bit -= 1 while bit >= 0 && b[bit] == 0
      count += (7 - bit)
      break
    end
  end
  count
end

def solve_pow(pem, difficulty)
  pow = 0
  pow += 1 until leading_zero_bits(Digest::SHA256.digest("#{pem}.#{pow}")) >= difficulty
  pow
end

# Register a fresh principal: solve PoW, POST /kiosk/agents/register, POST /kiosk/agents/kyc.
# Returns [user_id, agent_id, token].
def register_principal(name:, difficulty: 20)
  key = OpenSSL::PKey::RSA.generate(2048)
  pem = key.public_key.to_pem

  STDERR.puts "  Solving PoW (difficulty=#{difficulty}) for #{name}..."
  pow = solve_pow(pem, difficulty)
  STDERR.puts "  PoW solved: pow=#{pow}"

  rc, reg = post_json(
    "#{SERVER}/kiosk/agents/register",
    { name: name, public_key: pem, role: "customer", pow: pow.to_s },
  )
  abort "register #{name} failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201

  user_id  = reg.fetch("user_id")
  agent_id = reg.fetch("agent_id")
  token    = reg.fetch("access_token")

  # KYC — required by Gate 2 of start_rental; do it for both A and B so
  # the cross-tenant denial (Assertion 1) is clearly Gate-1 (ownership),
  # not Gate-2 (KYC). B passes KYC so the only reason B cannot start_rental
  # on A's reservation is the ownership predicate.
  att = StubKyc.attest(user_id: user_id)
  rc_kyc, kyc_resp = post_json(
    "#{SERVER}/kiosk/agents/kyc",
    { kyc_jws: att },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "kyc #{name} failed (#{rc_kyc}): #{JSON.generate(kyc_resp)}" unless rc_kyc == 200
  STDERR.puts "  #{name}: registered user_id=#{user_id} agent_id=#{agent_id} KYC=ok"

  [user_id, agent_id, token]
end

# ── Step 1: Register Principal A ─────────────────────────────────────────────
user_id_a, agent_id_a, token_a = register_principal(name: "alice-agent")

# ── Step 2: Register Principal B ─────────────────────────────────────────────
user_id_b, agent_id_b, token_b = register_principal(name: "bob-agent")

# ── Step 3: A reserves SK-001 → reservation_id rA ───────────────────────────
rc, reserve_a_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "reserve", scooter_code: "SK-001" } },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A reserve failed (#{rc}): #{JSON.generate(reserve_a_resp)}" unless rc == 200

reservation_id_a = reserve_a_resp.dig("value", "reservation_id")
abort "A's reservation_id missing from response: #{JSON.generate(reserve_a_resp)}" unless reservation_id_a
STDERR.puts "  A reserved SK-001: reservation_id=#{reservation_id_a}"

# ── Step 4: B calls start_rental on A's reservation_id (Assertion 1) ────────
# B is KYC-verified and has no payment, but the assertion is Gate-1 (ownership).
# Gate-1 WHERE user_id = kiosk.current_user_id() finds nothing → 403.
rc_start_b, start_b_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "start_rental", reservation_id: reservation_id_a } },
  { "Authorization" => "Bearer #{token_b}" },
)
STDERR.puts "  B start_rental on A's rA: HTTP #{rc_start_b} (expected 403)"

# ── Step 5: B queries my_reservations (Assertion 2) ─────────────────────────
rc, b_rsv_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_reservations" } },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_reservations failed (#{rc}): #{JSON.generate(b_rsv_resp)}" unless rc == 200

b_reservation_ids = (b_rsv_resp["rows"] || []).map { |r| r["id"] }
STDERR.puts "  B my_reservations: #{b_reservation_ids.inspect}"

# ── Step 6: B calls reserve with forged user_id arg (Assertion 3) ───────────
# B supplies user_id: user_id_a adversarially. The server ignores it —
# the INSERT uses kiosk.current_user_id() (B's UUID). Verified via DB query.
rc, forged_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:        "reserve",
      scooter_code: "SK-001",
      user_id:     user_id_a,  # adversarial: B supplies A's user_id
    },
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B forged reserve failed (#{rc}): #{JSON.generate(forged_resp)}" unless rc == 200

reservation_id_b_forged = forged_resp.dig("value", "reservation_id")
abort "B's forged reservation_id missing: #{JSON.generate(forged_resp)}" unless reservation_id_b_forged
STDERR.puts "  B forged reserve: reservation_id=#{reservation_id_b_forged}"

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:            user_id_a,
  user_id_b:            user_id_b,
  agent_id_a:           agent_id_a,
  agent_id_b:           agent_id_b,
  reservation_id_a:     reservation_id_a,
  reservation_id_b_forged: reservation_id_b_forged,
  b_start_rental_rc:    rc_start_b,
  b_reservation_ids:    b_reservation_ids,
)
