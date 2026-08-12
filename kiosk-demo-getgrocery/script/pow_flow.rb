# frozen_string_literal: true

# Getgrocery catalog-toll PoW driver (equihash).
#
# A commerce provider can toll anonymous browsing: the `catalog` query returns
# HTTP 402, the agent solves an Equihash challenge and retries. Proves the loop
# end-to-end with the real shipped solver. One JSON line on stdout.
#
# Usage (invoked by rake demo:pow — needs the server with KIOSK_POW_DEMO=1):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby script/pow_flow.rb
# Requires: python3 with numpy.

require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "open3"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")
# The TOY counter the initializer's on_bad_proof writes (K-590/K-498):
# PER-IDENTITY in sqlite — this driver asserts its own wrong nonce was counted
# against ITS identity and that an innocent second identity stayed at 0.
BAD_PROOF_DB = "/tmp/kiosk-getgrocery-bad-proof.sqlite3"

# equihash_solve / equihash_register come from the shared helper; the solver
# location is Kiosk::Pow::Equihash.solver_path, owned by the gem (K-627).
require_relative "../lib/equihash_register"
require_relative "../lib/bad_proof_counter"

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

# ── Register (register PoW solved transparently) ──────────────────────────────
_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
auth     = { "Authorization" => "Bearer #{reg.fetch("access_token")}" }
agent_id = reg.fetch("agent_id")

# A second, INNOCENT identity (K-498): registers, never submits a bad proof —
# its per-identity count must still be 0 after this flow's wrong nonce.
_key2, reg2 = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
other_agent_id = reg2.fetch("agent_id")

QUERY = { name: "catalog" }

# ── Initial catalog query → 402 ─────────────────────────────────────────────
rc_challenge, resp = post_json("#{SERVER}/kiosk/query", QUERY, auth)
abort "expected 402, got #{rc_challenge}: #{JSON.generate(resp)}" unless rc_challenge == 402
abort "expected pow_required" unless resp.dig("error", "code") == "pow_required"
challenges = resp.dig("error", "challenges")
proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }

# ── Wrong nonce → 403 + penalty ─────────────────────────────────────────────
_, neg = post_json("#{SERVER}/kiosk/query", QUERY, auth)
bad = { "indices" => (1..proofs.first[:nonce]["indices"].length).to_a, "header_nonce" => 0 }
# PoW proof rides in the Kiosk-PoW request header as raw JSON (ADR-0022), not
# the body — the body stays byte-identical so the challenge fingerprint matches.
rc_wrong, _ = post_json("#{SERVER}/kiosk/query", QUERY,
  auth.merge("Kiosk-PoW" => JSON.generate([{ challenge: neg.dig("error", "challenges").first, nonce: bad }])))
abort "expected 403 for wrong nonce, got #{rc_wrong}" unless rc_wrong == 403
# PER-IDENTITY (K-498): the offender's count moved, the innocent one's did not.
bad_proof_count       = BadProofCounter.count(BAD_PROOF_DB, agent_id)
other_bad_proof_count = BadProofCounter.count(BAD_PROOF_DB, other_agent_id)
unless other_bad_proof_count.zero?
  abort "expected bad_proof_count == 0 for the innocent identity, got #{other_bad_proof_count} — the counter is not per-identity (K-498)"
end

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
  other_bad_proof_count:   other_bad_proof_count,
  catalog_rows:            rows.size,
)
