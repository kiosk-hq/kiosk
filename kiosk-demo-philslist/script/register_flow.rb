# frozen_string_literal: true

# philslist registration-PoW driver.
#
# With no payment gate, the Equihash registration gate is the FREE board's
# anti-spam toll. It is ALWAYS ON (wired in the app config, no env flag). Proves
# it: POST /auth/register with no proof returns 402; the agent solves the
# challenge(s) and resubmits the SAME signed body, sending the proof(s) in the
# Kiosk-PoW request header (ADR-0022), getting 201. Then the fresh token POSTS A
# LISTING. One JSON line on stdout.
#
# Usage (invoked by rake demo:register):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby script/register_flow.rb
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

# equihash_solve comes from the shared helper (solver location owned by the
# kiosk-pow-equihash gem, K-627). The full equihash_register handshake it also
# defines is deliberately NOT used here: this driver spells out the 402 →
# solve → resubmit choreography step by step and asserts each status.
require_relative "../lib/equihash_register"

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
# The 402 is an RFC 9457 problem document: `challenges` is a TOP-LEVEL
# extension member, not nested under an `error` object.
challenges = resp_nopow["challenges"]
abort "402 without challenges[]" unless challenges.is_a?(Array) && challenges.any?

# ── Solve and resubmit the SAME signed body → expect 201 ────────────────────
# Proof(s) ride in the Kiosk-PoW request header as raw JSON (ADR-0022); the
# signed body stays byte-identical so the key-bound challenge fingerprint matches.
proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
rc_reg, reg = post_json("#{SERVER}/kiosk/auth/register", reg_body, { "Kiosk-PoW" => JSON.generate(proofs) })
abort "register with proof failed (#{rc_reg}): #{JSON.generate(reg)}" unless rc_reg == 201
token = reg.fetch("access_token")

# ── Use the fresh token: post a listing → 200 ───────────────────────────────
rc_post, posted = post_json("#{SERVER}/kiosk/post_listing",
                            { category_slug: "free",
                              title: "Freshly registered agent's ad", body: "Posted after solving the PoW toll" },
                            { "Authorization" => "Bearer #{token}" })
listing_id = posted["listing_id"]

# ── Robustness: a bad/missing category_slug returns a clean 400 that names the
# valid categories — NOT a 500 (regression guard for the find_by! crash).
#
# Since 0.4 this refusal comes from the SCHEMA LAYER rather than from the
# handler: `category_slug` is declared as an `enum`, `input_schema` is validated
# on every call, and the refusal names the closed set verbatim. That is K-717's
# rule delivered by the declaration instead of by hand-written prose — so the
# assertion below checks for the SLUGS, which is what an assistant recovers
# from, rather than for a sentence a handler happened to phrase. ──────────────
rc_badcat, badcat = post_json("#{SERVER}/kiosk/post_listing",
                              { category_slug: "not-a-real-slug",
                                title: "x", body: "y" },
                              { "Authorization" => "Bearer #{token}" })
# `message` became the problem document's `detail`.
badcat_msg = badcat["detail"].to_s

puts JSON.generate(
  http_register_no_pow: rc_nopow,
  http_register_solved: rc_reg,
  proofs_solved:        proofs.size,
  http_post:            rc_post,
  listing_id:           listing_id,
  http_post_bad_cat:    rc_badcat,
  bad_cat_lists_valid:  %w[furniture bikes electronics housing free].all? { |c| badcat_msg.include?(c) },
)
