# frozen_string_literal: true

# THE SECTION 5 AND SECTION 6 WIRE BYTES, KEPT (T-152).
#
# Same discipline as `pay_flow.rb`'s PAY_CAPTURE and `register_pow_flow.rb`'s
# POW_CAPTURE, and it exists for the same reason: `e2e/schema_conformance.rb`
# validates this origin's LIVE bytes against the PUBLISHED JSON Schemas, and it
# can only validate bytes something actually produced. T-149 published
# `auth.schema.json` and `binding.schema.json` and VENDORED them beside the
# other six, so the harness already loaded and compiled them — and validated
# nothing against them, which is K-822 exactly one layer on: hand-written
# examples on one side, code checked against its own specs on the other, the
# two never meeting.
#
# So this driver runs the two ceremonies end to end against the booted origin
# and writes down what went over the wire, request bodies included:
#
#   Section 5 (kiosk-pop)      challenge -> register (Equihash-tolled) ->
#                              login -> revoke, plus the decoded possession
#                              proof and the decoded access-token claims
#   Section 6.2/6.3 (link)     link -> claim -> unlink
#   Section 6.1 (device grant) device_authorization -> human approval on the
#                              real verify page -> the token poll
#   Section 6.1 (refusals)     the two OAuth error answers, which are the one
#                              place on this wire that is not an RFC 9457
#                              problem document
#
# THE HUMAN IS REAL. The link, unlink and approval legs authenticate through
# the shipped Devise form over `DeviseSession` — the same object the demos use
# — because those three are the session channel and there is no stub session
# to assert instead.
#
# WHY IT RUNS AFTER `assistant.sh` RATHER THAN BEFORE. The ceremonies here have
# side effects: they mint a third agent for alice, rebind it twice and then
# deactivate it. Everything the assistant suite asserts about alice and bob is
# already done by the time this runs, and `run.sh` takes its audit-sink row
# counts afterwards, so nothing downstream can read this driver's residue as
# its own.
#
# NO SLEEP, DELIBERATELY. RFC 8628 `slow_down` is keyed on the PREVIOUS poll of
# the same `device_code` ({DeviceCodeGrant.polled_too_fast?}), so a ceremony
# that polls exactly once is never too fast — the pacing `sleep` the demos'
# claim flows carry is realism, not a requirement, and a gate does not pay six
# seconds for it.
#
# Usage (invoked by e2e/run.sh from the generated app dir):
#
#   SERVER_URL=… KIOSK_ISSUER=… HUMAN_EMAIL=… HUMAN_PASSWORD=… SOLVE_PY=… \
#     AUTH_CAPTURE=/tmp/auth-capture.json bundle exec ruby auth_wire_capture.rb
#
# Prints ONE JSON line of counters for the log; aborts on any unexpected status.

require "base64"
require "json"
require "jwt"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

require_relative "../../kiosk-demo-stylish/script/devise_session"
require_relative "equihash_register"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
EMAIL    = ENV.fetch("HUMAN_EMAIL")
PASSWORD = ENV.fetch("HUMAN_PASSWORD")
CAPTURE  = ENV.fetch("AUTH_CAPTURE")

def get_json(url, headers = {})
  uri = URI(url)
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# The OAuth half of the ceremony is `application/x-www-form-urlencoded` — the
# spec's one deliberate exception to the JSON wire — so it cannot go through
# `post_json`, and it carries no cookie and no Bearer: anything in it is an
# assertion by a stranger, which is the property the endpoint is designed
# around.
def post_form(url, form)
  uri = URI(url)
  req = Net::HTTP::Post.new(uri)
  req.set_form_data(form)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# The decoded payload of a compact JWS/JWT, without verifying — the point here
# is to keep the bytes a verifier reads, not to re-verify what the origin
# already accepted.
def payload_of(compact)
  seg = compact.to_s.split(".")[1].to_s
  JSON.parse(Base64.urlsafe_decode64(seg + ("=" * ((4 - (seg.length % 4)) % 4))))
end

# A fresh possession proof for `key`: Section 5.1's challenge, signed as
# Section 5.2's payload. Returns [the compact JWS, the challenge document].
def possession_proof(key, pem)
  rc, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc}): #{JSON.generate(ch)}" unless rc == 200

  signed = JWT.encode(
    { aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
    key, "RS256",
  )
  [signed, ch]
end

cap = {}

# ── Section 5.1/5.2/5.3 — challenge, possession proof, register ─────────────
#
# The register leg goes through the SHARED helper rather than a second copy of
# the toll dance, and `on_proofs:` is not used here: the solved proof is
# `register_pow_flow.rb`'s subject and validating it twice would say nothing
# new. What this leg is here for is the 201 body and the challenge that opened
# it.
reg_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: ->(url) { get_json(url) },
  post_json: ->(url, body, headers = {}) { post_json(url, body, headers) },
)
reg_pem = reg_key.public_key.to_pem
cap["registration"] = reg

# The challenge document and the proof payload are captured from a SECOND
# handshake with the same key rather than reached into the helper for: a
# challenge is single-use, so the one the helper spent is gone, and this is the
# same endpoint answering the same key.
login_signed, challenge_doc = possession_proof(reg_key, reg_pem)
cap["challenge"]        = challenge_doc
cap["possession_proof"] = payload_of(login_signed)

# Section 5.4 — what the operator put inside the token it just minted.
cap["access_token_claims"] = payload_of(reg.fetch("access_token"))

# ── Section 5.3 — login, with the credential request that produced it ───────
login_body = { "public_key" => reg_pem, "signed" => login_signed }
rc, login = post_json("#{SERVER}/kiosk/auth/login", login_body)
abort "login failed (#{rc}): #{JSON.generate(login)}" unless rc == 200
cap["credential_request"] = login_body
cap["token_login"]        = login

# ── Section 5.5 — revoke answers the SAME object as login ───────────────────
#
# Revoking stamps a per-identity watermark and hands back a token issued after
# it, so the caller is not signed out by its own call. Section 5.5 named no
# member of that answer until 2026-08-30 (K-1249); `#/$defs/token` now says it
# is login's object member for member, and this is the byte that has to agree.
rc, revoked = post_json("#{SERVER}/kiosk/auth/revoke", {},
                        { "Authorization" => "Bearer #{login.fetch("access_token")}" })
abort "revoke failed (#{rc}): #{JSON.generate(revoked)}" unless rc == 200
cap["token_revoke"] = revoked

# ── Section 6.2 — the human's link code, redeemed by the agent's key ────────
session = DeviseSession.new(SERVER)
session.sign_in!(email: EMAIL, password: PASSWORD)

rc, link = session.post_json("/kiosk/auth/link", {}, { session: true })
abort "link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201
cap["link_code"] = link

claim_signed, = possession_proof(reg_key, reg_pem)
claim_body = { "code" => link.fetch("link_code"), "public_key" => reg_pem, "signed" => claim_signed }
rc, claimed = post_json("#{SERVER}/kiosk/auth/claim", claim_body)
abort "claim failed (#{rc}): #{JSON.generate(claimed)}" unless rc == 201
cap["claim_request"]  = claim_body
cap["claim_response"] = claimed

# ── Section 6.1 — the two OAuth refusals ────────────────────────────────────
#
# Both are pure refusals: neither creates a row, and neither touches the poll
# registry, so they cost the ceremony below nothing. The first is the clause
# `#/$defs/oauthError` was widened for — Section 6.1 step 1 REQUIRES
# `invalid_request` for a `role` or `scope` parameter, and an enum written from
# the section's own six-code closing list could not have expressed it.
rc, role_refused = post_form("#{SERVER}/kiosk/oauth/device_authorization",
                             { "client_id" => "e2e-auth-capture",
                               "public_key" => reg_pem, "role" => "owner" })
abort "a role parameter was not refused (#{rc}): #{JSON.generate(role_refused)}" unless rc == 400
cap["oauth_error_role_refused"] = role_refused

rc, bad_grant = post_form("#{SERVER}/kiosk/oauth/token", { "grant_type" => "client_credentials" })
abort "an unknown grant_type was not refused (#{rc}): #{JSON.generate(bad_grant)}" unless rc == 400
cap["oauth_error_unsupported_grant"] = bad_grant

# ── Section 6.1 — the device grant, all three steps ─────────────────────────
rc, da = post_form("#{SERVER}/kiosk/oauth/device_authorization",
                   { "client_id" => "e2e-auth-capture", "public_key" => reg_pem })
abort "device_authorization failed (#{rc}): #{JSON.generate(da)}" unless rc == 200
cap["device_authorization"] = da

# The human approves on the REAL verify page: GET for the page and its CSRF
# token, POST the decision over the same session.
user_code = da.fetch("user_code")
show = session.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
abort "verify page: #{show.code}" unless show.code.to_i == 200
form = { "user_code" => user_code, "decision" => "approve" }
if (csrf = session.csrf_token(show.body))
  form["authenticity_token"] = csrf
end
approve = session.post_form("/kiosk/oauth/device/verify", form)
abort "approval failed (#{approve.code})" unless [200, 302, 303].include?(approve.code.to_i)

poll_signed, = possession_proof(reg_key, reg_pem)
rc, granted = post_form("#{SERVER}/kiosk/oauth/token",
                        { "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
                          "device_code" => da.fetch("device_code"),
                          "signed" => poll_signed })
abort "token poll failed (#{rc}): #{JSON.generate(granted)}" unless rc == 200
cap["device_token_response"] = granted

# ── Section 6.3 — unlink, which answers 204 and no body at all ──────────────
#
# It is also this driver's own cleanup: the agent it minted is deactivated
# before the harness moves on, so nothing it left behind can be mistaken for
# one of the two principals the suite asserts about.
#
# Dialled through `DeviseSession#request` rather than `#post_json`, because the
# assertion is about the RESPONSE and not only its status: §6.2 says 204 and
# «no body at all», so the body's LENGTH is part of what has to be captured,
# and the JSON wrapper hands back a parsed Hash that cannot tell an empty body
# from an unparseable one.
unlink_body = { "agent_id" => cap.fetch("claim_response").fetch("agent_id") }
unlink_req = Net::HTTP::Post.new(URI("#{SERVER}/kiosk/auth/unlink"),
                                 { "Content-Type" => "application/json" })
unlink_req["Cookie"] = session.cookie_header
unlink_req.body = JSON.generate(unlink_body)
unlink = session.request(unlink_req)
rc = unlink.code.to_i
abort "unlink failed (#{rc}): #{unlink.body.inspect}" unless rc == 204
cap["unlink_request"]  = unlink_body
cap["unlink_status"]   = rc
cap["unlink_body_len"] = unlink.body.to_s.length

File.write(CAPTURE, JSON.generate(cap))
puts JSON.generate(objects: cap.keys.length, agent_id: cap.fetch("claim_response").fetch("agent_id"))
