# frozen_string_literal: true

# Hoteling browse-heavy PoW driver (priced pagination).
#
# Hotel search is legitimately browse-heavy — an assistant compares many
# options. This vertical does not treat that as suspicion; it prices DEPTH:
# the first few queries are free, then each extra one costs proof-of-work,
# escalating with the query rate. This driver registers once, then
# runs a burst of `properties` queries and records, per query, how many proofs
# the provider demanded — showing the free-then-priced curve.
#
# Usage (invoked by rake demo:browse — needs the server with KIOSK_POW_BROWSE_DEMO=1):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby browse_flow.rb
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
BROWSES  = Integer(ENV.fetch("BROWSES", "7"))

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

# ── Register (register PoW solved transparently when the provider gates
#    registration — KIOSK_POW_REGISTER_DEMO=1) ─────────────────────────────────
require_relative "lib/equihash_register"
_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
token = reg.fetch("access_token")
auth  = { "Authorization" => "Bearer #{token}" }

# ── Burst of `properties` browses; record proofs demanded per browse ────────
QUERY = { name: "properties" }
curve = []
BROWSES.times do |i|
  rc, resp = post_json("#{SERVER}/kiosk/query", QUERY, auth)
  if rc == 402
    challenges = resp.dig("error", "challenges")
    abort "browse #{i}: 402 without challenges[]" unless challenges.is_a?(Array) && challenges.any?
    proofs = challenges.map { |c| { challenge: c, nonce: solve(c) } }
    # PoW proof rides in the Kiosk-PoW request header as raw JSON (ADR-0022),
    # not the body — the body stays byte-identical so the challenge fingerprint
    # matches on retry.
    rc, resp = post_json("#{SERVER}/kiosk/query", QUERY, auth.merge("Kiosk-PoW" => JSON.generate(proofs)))
    curve << proofs.size
  else
    curve << 0
  end
  abort "browse #{i} not served (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  $stderr.puts "  [browse] query #{i + 1}: #{curve.last} proof(s), served"
end

# Assertions: the first browses are free (0 proofs), and the demanded count is
# non-decreasing and eventually positive — depth got priced.
free_prefix   = curve.take_while { |n| n.zero? }.length
became_priced = curve.any?(&:positive?)
monotonic     = curve.each_cons(2).all? { |a, b| b >= a }

puts JSON.generate(
  browses:       BROWSES,
  curve:         curve,
  free_prefix:   free_prefix,
  became_priced: became_priced,
  monotonic:     monotonic,
)
