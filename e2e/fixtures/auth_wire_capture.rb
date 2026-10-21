# frozen_string_literal: true

# THE SECTION 5 AND SECTION 6 WIRE BYTES, KEPT.
#
# Same discipline as `pay_flow.rb`'s PAY_CAPTURE and `register_pow_flow.rb`'s
# POW_CAPTURE, and it exists for the same reason: `e2e/schema_conformance.rb`
# validates this origin's LIVE bytes against the PUBLISHED JSON Schemas, and it
# can only validate bytes something actually produced. `auth.schema.json` and
# `binding.schema.json` are VENDORED beside the other six, and loading and
# compiling them is not the same as validating anything against them:
# hand-written examples on one side, code checked against its own specs on the
# other, the two never meeting.
#
# So this driver runs the two ceremonies end to end against the booted origin
# and writes down what went over the wire, request bodies included:
#
#   Section 5 (OAuth)          register (RFC 7591, Equihash-tolled) and its
#                              refusal -> client_credentials token (RFC 7523
#                              client assertion, RFC 9449 DPoP) and its refusal
#                              -> a wire call -> rotate, plus the decoded client
#                              assertions, DPoP proofs and access-token claims
#   Section 6.2/6.3 (link)     link -> claim (204) -> unlink
#   Section 6.1 (device grant) device_authorization -> human approval on the
#                              real verify page -> the token poll
#   Section 6.1 (refusals)     two OAuth error answers; the OAuth errors are
#                              the one kind of answer on this wire that is
#                              not an RFC 9457 problem document
#
# THE HUMAN IS REAL. The link, unlink and approval legs authenticate through
# the shipped Devise form over `Kiosk::UserIdentityProviders::DeviseSession`
# — the same object the demos use
# — because those three are the session channel and there is no stub session
# to assert instead.
#
# WHY IT RUNS AFTER `assistant.sh` RATHER THAN BEFORE. The ceremonies here have
# side effects: they register a third agent, bind it to alice twice and then
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
#   SERVER_URL=… KIOSK_ISSUER=… HUMAN_EMAIL=… HUMAN_PASSWORD=… \
#     AUTH_CAPTURE=/tmp/auth-capture.json bundle exec ruby auth_wire_capture.rb
#
# Prints ONE JSON line of counters for the log; aborts on any unexpected status.

require 'base64'
require 'json'
require 'jwt'
require 'net/http'
require 'kiosk/test_helpers/dpop'
require 'kiosk/test_helpers/wire'
require 'openssl'
require 'securerandom'
require 'uri'

require 'kiosk/user_identity_providers/devise_session'
require_relative 'equihash_register'

SERVER   = ENV.fetch('SERVER_URL')
ISSUER   = ENV.fetch('KIOSK_ISSUER')
EMAIL    = ENV.fetch('HUMAN_EMAIL')
PASSWORD = ENV.fetch('HUMAN_PASSWORD')
CAPTURE  = ENV.fetch('AUTH_CAPTURE')

def get_json(url, headers = {})
  uri = URI(url)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { 'Content-Type' => 'application/json' }.merge(headers))
  req.body = JSON.generate(body)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

# The OAuth requests are `application/x-www-form-urlencoded` — the spec's one
# deliberate exception to the JSON wire — so they cannot go through `post_json`.
def post_form(url, form, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, headers)
  req.set_form_data(form)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

# The link-code claim and the first token poll of a device code pay the same
# toll as registration: on `402 pow_required`, solve every challenge and yield
# the `Kiosk-PoW` header for the SAME request again.
def paying_toll(answer)
  rc, problem = answer
  return answer unless rc == 402 && problem['code'] == 'pow_required'

  proofs = problem.fetch('challenges').map { |c| { challenge: c, nonce: equihash_solve(c) } }
  yield('Kiosk-PoW' => JSON.generate(proofs))
end

# The decoded payload of a compact JWS/JWT, without verifying — the point here
# is to keep the bytes a verifier reads, not to re-verify what the origin
# already accepted.
def payload_of(compact)
  seg = compact.to_s.split('.')[1].to_s
  JSON.parse(Base64.urlsafe_decode64(seg + ('=' * ((4 - (seg.length % 4)) % 4))))
end

cap = {}

# ── Section 5.1 — register, and the one registration refusal ────────────────
#
# The register leg goes through the SHARED helper rather than a second copy of
# the toll dance, and `on_proofs:` is not used here: the solved proof is
# `register_pow_flow.rb`'s subject and validating it twice would say nothing
# new. What this leg is here for is the request and the 201 body.
reg_key, reg = equihash_register(server: SERVER)
client_id = reg.fetch('client_id')
cap['registration_request'] = registration_body(reg_key)
cap['registration'] = reg

# A body whose JWK Set holds no key is refused before the toll is asked for.
rc, refused = post_json("#{SERVER}/kiosk/oauth/register", { jwks: { keys: [] } })
abort "an empty jwks was not refused (#{rc}): #{JSON.generate(refused)}" unless rc == 400
cap['registration_error'] = refused

# ── Section 5.2/5.3/5.4 — the client_credentials token, and its refusal ──────
TOKEN_URL = "#{SERVER}/kiosk/oauth/token".freeze
token_proof = Kiosk::TestHelpers::Dpop.headers(nil, reg_key, method: 'POST', url: "#{ISSUER}/kiosk/oauth/token")
token_form = { 'grant_type' => 'client_credentials', **assertion_params(client_id, reg_key, ISSUER) }
rc, issued = post_form(TOKEN_URL, token_form, token_proof)
abort "token request failed (#{rc}): #{JSON.generate(issued)}" unless rc == 200
cap['client_assertion']    = payload_of(token_form.fetch('client_assertion'))
cap['token_request_proof'] = payload_of(token_proof.fetch('DPoP'))
cap['token_response']      = issued
cap['access_token_claims'] = payload_of(issued.fetch('access_token'))

# The same request with no client assertion is the one 401 of this wire's OAuth errors.
no_assertion_proof = Kiosk::TestHelpers::Dpop.headers(nil, reg_key, method: 'POST', url: "#{ISSUER}/kiosk/oauth/token")
rc, unauthenticated = post_form(TOKEN_URL, { 'grant_type' => 'client_credentials' }, no_assertion_proof)
abort "a token request with no client assertion was not refused (#{rc}): #{JSON.generate(unauthenticated)}" unless rc == 401
cap['oauth_error_invalid_client'] = unauthenticated

# ── Section 5.6 — a DPoP proof that carries the token, on a wire call ─────────
salons_url = "#{SERVER}/kiosk/salons"
salons_dpop = Kiosk::TestHelpers::Dpop.headers(issued.fetch('access_token'), reg_key, method: 'GET', url: salons_url)
rc, = get_json(salons_url, salons_dpop)
abort "the wire call with the token failed (#{rc})" unless rc == 200
cap['dpop_proof'] = payload_of(salons_dpop.fetch('DPoP'))

# ── Section 6.2 — the human's link code, redeemed by the client ─────────────
session = Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)
session.sign_in!(email: EMAIL, password: PASSWORD)

rc, link = session.post_json('/kiosk/auth/link', {}, { session: true })
abort "link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201
cap['link_code'] = link

claim_body = { 'code' => link.fetch('link_code'), **assertion_params(client_id, reg_key, ISSUER) }
claim_url = "#{SERVER}/kiosk/auth/claim"
rc, claimed = paying_toll(post_json(claim_url, claim_body)) { |pow| post_json(claim_url, claim_body, pow) }
abort "claim failed (#{rc}): #{JSON.generate(claimed)}" unless rc == 204
cap['claim_request'] = claim_body
cap['claim_status']  = rc

# ── Section 6.1 — the two OAuth refusals ────────────────────────────────────
#
# Both are pure refusals: neither creates a row, and neither touches the poll
# registry, so they cost the ceremony below nothing. The first is the clause
# `#/$defs/oauthError` carries `invalid_request` for: Section 6.1 step 1
# REQUIRES it for a `role` or `scope` parameter.
rc, role_refused = post_form("#{SERVER}/kiosk/oauth/device_authorization",
                             { **assertion_params(client_id, reg_key, ISSUER), 'role' => 'owner' })
abort "a role parameter was not refused (#{rc}): #{JSON.generate(role_refused)}" unless rc == 400
cap['oauth_error_role_refused'] = role_refused

rc, bad_grant = post_form(TOKEN_URL, { 'grant_type' => 'password' })
abort "an unknown grant_type was not refused (#{rc}): #{JSON.generate(bad_grant)}" unless rc == 400
cap['oauth_error_unsupported_grant'] = bad_grant

# ── Section 6.1 — the device grant, all three steps ─────────────────────────
rc, da = post_form("#{SERVER}/kiosk/oauth/device_authorization", assertion_params(client_id, reg_key, ISSUER))
abort "device_authorization failed (#{rc}): #{JSON.generate(da)}" unless rc == 200
cap['device_authorization'] = da

# The human approves on the REAL verify page: GET for the page and its CSRF
# token, POST the decision over the same session.
user_code = da.fetch('user_code')
show = session.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
abort "verify page: #{show.code}" unless show.code.to_i == 200
form = { 'user_code' => user_code, 'decision' => 'approve' }
if (csrf = session.csrf_token(show.body))
  form['authenticity_token'] = csrf
end
approve = session.post_form('/kiosk/oauth/device/verify', form)
abort "approval failed (#{approve.code})" unless [200, 302, 303].include?(approve.code.to_i)

# A new client assertion and a new DPoP proof for each send, also for the send that pays the toll.
poll = lambda do |pow = {}|
  form = { 'grant_type' => 'urn:ietf:params:oauth:grant-type:device_code', 'device_code' => da.fetch('device_code'),
           **assertion_params(client_id, reg_key, ISSUER) }
  proof = Kiosk::TestHelpers::Dpop.headers(nil, reg_key, method: 'POST', url: "#{ISSUER}/kiosk/oauth/token")
  post_form(TOKEN_URL, form, proof.merge(pow))
end
rc, granted = paying_toll(poll.call) { |pow| poll.call(pow) }
abort "token poll failed (#{rc}): #{JSON.generate(granted)}" unless rc == 200
cap['device_token_response'] = granted

# ── Section 5.7 — the client puts a new key on its identity ──────────────────
#
# Each key signs a client assertion, and the old key's assertion names the new
# key by its thumbprint. The client stays, so the unlink below still finds the
# agent the claim bound.
new_key = OpenSSL::PKey::RSA.generate(2048)
rotate_body = { 'client_assertion_type' => ASSERTION_TYPE,
                'client_assertion' => client_assertion(client_id, reg_key, ISSUER,
                                                       new_key: Kiosk::TestHelpers::Dpop.thumbprint(new_key)),
                'new_client_assertion' => client_assertion(client_id, new_key, ISSUER),
                'jwks' => { 'keys' => [Kiosk::TestHelpers::Dpop.jwk(new_key)] } }
rc, rotated = post_json("#{SERVER}/kiosk/auth/rotate", rotate_body)
abort "rotate failed (#{rc}): #{JSON.generate(rotated)}" unless rc == 200
cap['rotation_request']   = rotate_body
cap['rotation_assertion'] = payload_of(rotate_body.fetch('client_assertion'))
cap['rotation_response']  = rotated
abort 'the rotation answered another client' unless rotated.fetch('client_id') == client_id

# ── Section 6.3 — unlink, which answers 204 and no body at all ──────────────
#
# It is also this driver's own cleanup: the agent it registered is deactivated
# before the harness moves on, so nothing it left behind can be mistaken for
# one of the two principals the suite asserts about.
#
# Dialled through `Kiosk::UserIdentityProviders::DeviseSession#request`
# rather than `#post_json`, because the
# assertion is about the RESPONSE and not only its status: §6.2 says 204 and
# «no body at all», so the body's LENGTH is part of what has to be captured,
# and the JSON wrapper hands back a parsed Hash that cannot tell an empty body
# from an unparseable one.
unlink_body = { 'agent_id' => client_id }
unlink_req = Net::HTTP::Post.new(URI("#{SERVER}/kiosk/auth/unlink"),
                                 { 'Content-Type' => 'application/json' })
unlink_req['Cookie'] = session.cookie_header
unlink_req.body = JSON.generate(unlink_body)
unlink = session.request(unlink_req)
rc = unlink.code.to_i
abort "unlink failed (#{rc}): #{unlink.body.inspect}" unless rc == 204
cap['unlink_request']  = unlink_body
cap['unlink_status']   = rc
cap['unlink_body_len'] = unlink.body.to_s.length

File.write(CAPTURE, JSON.generate(cap))
puts JSON.generate(objects: cap.keys.length, agent_id: client_id)
