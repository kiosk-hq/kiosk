# frozen_string_literal: true

# Getgrocery catalog-toll PoW driver (equihash).
#
# A commerce provider can toll anonymous browsing: the `catalog` query returns
# HTTP 402, the agent solves an Equihash challenge and retries. Proves the loop
# end-to-end with the real shipped solver. One JSON line on stdout.
#
# Usage (invoked by rake demo:pow — needs the server with KIOSK_POW_DEMO=1):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby pow_flow.rb
# Requires: python3 with numpy.

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
BAD_PROOF_FILE = "/tmp/kiosk-getgrocery-bad-proof.count"

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

def solve(challenge)
  out, status = Open3.capture2("python3", SOLVE_PY, JSON.generate(challenge))
  abort "solve.py exited non-zero: #{out}" unless status.success?
  parsed = JSON.parse(out)
  abort "solve.py error: #{parsed["error"]}" if parsed.key?("error")
  { "indices" => parsed.fetch("indices"), "header_nonce" => parsed.fetch("header_nonce") }
end

# ── Register ────────────────────────────────────────────────────────────────
key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
rc_ch, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
rc, reg = post_json("#{SERVER}/kiosk/auth/register", { public_key: pem, signed: pop })
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
auth = { "Authorization" => "Bearer #{reg.fetch("access_token")}" }

QUERY = { name: "catalog" }

# ── Initial catalog query → 402 ─────────────────────────────────────────────
rc_challenge, resp = post_json("#{SERVER}/kiosk/query", QUERY, auth)
abort "expected 402, got #{rc_challenge}: #{JSON.generate(resp)}" unless rc_challenge == 402
abort "expected pow_required" unless resp.dig("error", "code") == "pow_required"
challenges = resp.dig("error", "challenges")
proofs = challenges.map { |c| { challenge: c, nonce: solve(c) } }

# ── Wrong nonce → 403 + penalty ─────────────────────────────────────────────
_, neg = post_json("#{SERVER}/kiosk/query", QUERY, auth)
bad = { "indices" => (1..proofs.first[:nonce]["indices"].length).to_a, "header_nonce" => 0 }
# PoW proof rides in the Kiosk-PoW request header as raw JSON (ADR-0022), not
# the body — the body stays byte-identical so the challenge fingerprint matches.
rc_wrong, _ = post_json("#{SERVER}/kiosk/query", QUERY,
  auth.merge("Kiosk-PoW" => JSON.generate([{ challenge: neg.dig("error", "challenges").first, nonce: bad }])))
abort "expected 403 for wrong nonce, got #{rc_wrong}" unless rc_wrong == 403
bad_proof_count = File.read(BAD_PROOF_FILE).to_i rescue 0

# ── Correct proof → 200 served ──────────────────────────────────────────────
rc_served, served_resp = post_json("#{SERVER}/kiosk/query", QUERY, auth.merge("Kiosk-PoW" => JSON.generate(proofs)))
rows = served_resp.fetch("rows", [])
abort "expected 200 + rows, got #{rc_served}: #{JSON.generate(served_resp)}" unless rc_served == 200 && rows.any?

puts JSON.generate(
  http_challenge:          rc_challenge,
  http_served_after_solve: rc_served,
  http_wrong_nonce:        rc_wrong,
  served:                  true,
  proofs_solved:           proofs.size,
  bad_proof_count:         bad_proof_count,
  catalog_rows:            rows.size,
)
