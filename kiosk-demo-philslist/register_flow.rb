# frozen_string_literal: true

# philslist registration-PoW driver.
#
# With no payment gate, the optional Equihash registration gate is the FREE
# board's anti-spam toll. Proves it: POST /auth/register with no proof returns
# 402; the agent solves the challenge(s) and resubmits the SAME signed body with
# pow:{proofs:}, getting 201. Then the fresh token POSTS A LISTING. One JSON
# line on stdout.
#
# Usage (invoked by rake demo:register — needs KIOSK_POW_REGISTER_DEMO=1):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby register_flow.rb
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

# ── Challenge + PoP ─────────────────────────────────────────────────────────
key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
rc_ch, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
reg_body = { public_key: pem, signed: pop }

# ── Register with no proof → expect 402 pow_required ────────────────────────
rc_nopow, resp_nopow = post_json("#{SERVER}/kiosk/auth/register", reg_body)
abort "expected 402 without proof, got #{rc_nopow}: #{JSON.generate(resp_nopow)}" unless rc_nopow == 402
challenges = resp_nopow.dig("error", "challenges")
abort "402 without challenges[]" unless challenges.is_a?(Array) && challenges.any?

# ── Solve and resubmit the SAME signed body → expect 201 ────────────────────
proofs = challenges.map { |c| { challenge: c, nonce: solve(c) } }
rc_reg, reg = post_json("#{SERVER}/kiosk/auth/register", reg_body.merge(pow: { proofs: proofs }))
abort "register with proof failed (#{rc_reg}): #{JSON.generate(reg)}" unless rc_reg == 201
token = reg.fetch("access_token")

# ── Use the fresh token: post a listing → 200 ───────────────────────────────
rc_post, posted = post_json("#{SERVER}/kiosk/run",
                            { name: "post_listing", category_slug: "free",
                              title: "Freshly registered agent's ad", body: "Posted after solving the PoW toll" },
                            { "Authorization" => "Bearer #{token}" })
listing_id = posted.dig("value", "listing_id")

# ── Robustness: a bad/missing category_slug returns a clean 400 that names the
# valid categories — NOT a 500 (regression guard for the find_by! crash) ──────
rc_badcat, badcat = post_json("#{SERVER}/kiosk/run",
                              { name: "post_listing", category_slug: "not-a-real-slug",
                                title: "x", body: "y" },
                              { "Authorization" => "Bearer #{token}" })
badcat_msg = badcat.dig("error", "message").to_s

puts JSON.generate(
  http_register_no_pow: rc_nopow,
  http_register_solved: rc_reg,
  proofs_solved:        proofs.size,
  http_post:            rc_post,
  listing_id:           listing_id,
  http_post_bad_cat:    rc_badcat,
  bad_cat_lists_valid:  badcat_msg.include?("valid categories"),
)
