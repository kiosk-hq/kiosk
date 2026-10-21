# frozen_string_literal: true

# Account-binding proof: the full claim ceremony (a registered client → human
# approval on the verify page → token poll with a client assertion), a protocol
# call as the bound assistant account, the human-initiated link-code redeem,
# and unlink.
# Prints a JSON result line on stdout; the shell asserts each field.
require 'jwt'
require 'json'
require 'net/http'
require 'kiosk/test_helpers/dpop'
require 'kiosk/test_helpers/wire'
require 'uri'
require 'openssl'
require 'securerandom'

# The human half of this ceremony is a REAL browser session: there is
# no stub user-IdP left to hand this driver a `user:u-<uuid>` token. The
# cookie-jar-and-CSRF helper is the demos' single copy — reached here rather
# than duplicated into e2e/fixtures, because an eighth copy of a mechanism is
# how the seventh one drifts.
require 'kiosk/user_identity_providers/devise_session'

SERVER   = ENV.fetch('SERVER_URL')
ISSUER   = ENV.fetch('KIOSK_ISSUER')
HUMAN    = ENV.fetch('HUMAN_USER_ID') # seeded account holder (alice)
EMAIL    = ENV.fetch('HUMAN_EMAIL')
PASSWORD = ENV.fetch('HUMAN_PASSWORD')

# Alice's browser, signed in once and held for every human-side call below.
HUMAN_SESSION = Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)

# The proof-of-work tolls paid, by path. The link-code claim and the first
# token poll of a device code pay the same toll as register on this origin.
TOLLS = Hash.new(0)

# Sends the request; on `402 pow_required` it solves the challenges and sends
# the SAME request again with the `Kiosk-PoW` header.
def paying(uri, &build)
  status, body = deliver(uri, build.call({}))
  return [status, body] unless status == 402 && body['code'] == 'pow_required'

  TOLLS[uri.path] += 1
  deliver(uri, build.call('Kiosk-PoW' => JSON.generate(Kiosk::TestHelpers::Wire.solve(body.fetch('challenges')))))
end

def deliver(uri, req)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

def post_json(url, body, headers = {})
  uri = URI(url)
  paying(uri) do |toll|
    Net::HTTP::Post.new(uri, { 'Content-Type' => 'application/json' }.merge(headers).merge(toll))
                   .tap { it.body = JSON.generate(body) }
  end
end

def get_json(url, headers = {})
  uri = URI(url)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

def post_form(url, form, headers = {})
  uri = URI(url)
  paying(uri) { |toll| Net::HTTP::Post.new(uri, headers.merge(toll)).tap { it.set_form_data(form) } }
end

require_relative 'equihash_register'

# A fresh key, registered as a client (RFC 7591). The registration toll is not
# counted in TOLLS: this driver asserts the tolls of the claim and the poll.
def registered_client
  key, reg = equihash_register(server: SERVER)
  [key, reg.fetch('client_id')]
end

# A token request (RFC 6749) with a new client assertion and a new DPoP proof
# for each send, also for the send that pays the toll. `assert: false` sends no
# client assertion.
def token_post(client_id, key, form, assert: true)
  uri = URI(TOKEN_URL)
  paying(uri) do |toll|
    proof = Kiosk::TestHelpers::Dpop.headers(nil, key, method: 'POST', url: "#{ISSUER}/kiosk/oauth/token")
    body = assert ? form.merge(assertion_params(client_id, key, ISSUER)) : form
    Net::HTTP::Post.new(uri, proof.merge(toll)).tap { it.set_form_data(body) }
  end
end

TOKEN_URL = "#{SERVER}/kiosk/oauth/token".freeze
GRANT     = 'urn:ietf:params:oauth:grant-type:device_code'
results   = {}

# ── claim ceremony: the agent registers a FRESH key first ──
key, client_id = registered_client

# THE OPENING REQUEST MAY NOT NAME A ROLE.
#
# The client authenticates, but anything it carries beyond that is the
# assistant's own claim. The engine does not read `role` (or its OAuth spelling
# `scope`) off it at all: the role comes from the approving human, and the
# parameter is REFUSED rather than ignored.
#
# THE DECLARED VALUE IS THE ONE THAT MATTERS. An UNDECLARED role (`owner` here —
# this origin declares only `customer`) is refused by anything that filters on
# membership of `config.roles`, so a probe using only that distinguishes
# nothing. `role=customer` is the probe with teeth: it is the value a
# membership filter would wave through, so the refusal it draws can only come
# from the parameter being refused outright. Both transports
# are probed because the controller reads `params[:role]`, which Rails fills
# from a form body and a JSON body alike — a guard on one would not be a guard.
DEVICE_AUTHORIZATION = "#{SERVER}/kiosk/oauth/device_authorization".freeze
role_probes = [%w[role customer], %w[scope customer], %w[role owner]].map do |param, value|
  code, body = post_form(DEVICE_AUTHORIZATION, assertion_params(client_id, key, ISSUER).merge(param => value))
  "#{param}=#{value}:#{code}:#{body['error']}"
end
code, body = post_json(DEVICE_AUTHORIZATION, assertion_params(client_id, key, ISSUER).merge('role' => 'customer'))
role_probes << "json-role=customer:#{code}:#{body['error']}"
results[:role_refused] = role_probes

rc, da = post_form(DEVICE_AUTHORIZATION, assertion_params(client_id, key, ISSUER))
abort "device_authorization failed: #{rc} #{da}" unless rc == 200
device_code = da.fetch('device_code')
user_code   = da.fetch('user_code')
results[:da_fields] = %w[device_code user_code verification_uri expires_in interval].all? { |k| da.key?(k) }

# Poll with a valid client assertion before approval → authorization_pending.
rc, tok = token_post(client_id, key, { grant_type: GRANT, device_code: device_code })
results[:pending] = [rc, tok['error']]

# Polling faster than the advertised `interval` answers slow_down
# (RFC 8628 §3.5) — assert it once, then honor the pace.
rc, tok = token_post(client_id, key, { grant_type: GRANT, device_code: device_code })
results[:slow_down] = [rc, tok['error']]

# The human signs in through the REAL Devise form, then approves on the verify
# page: GET first (the page + its CSRF token), then POST approve over the same
# session. A failed sign-in raises, so `signed_in` is never a wish.
HUMAN_SESSION.sign_in!(email: EMAIL, password: PASSWORD)
results[:signed_in] = true

show = HUMAN_SESSION.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
abort "verify page: #{show.code}" unless show.code.to_i == 200
form = { user_code: user_code, decision: 'approve' }
if (csrf = HUMAN_SESSION.csrf_token(show.body))
  form[:authenticity_token] = csrf
end
results[:approve] = HUMAN_SESSION.post_form('/kiosk/oauth/device/verify', form).code.to_i

# Client authentication, at the moment it matters: an APPROVED row polled
# WITHOUT the client assertion is refused (invalid_client) and stays
# approved — nothing binds. The refusal comes before the grant, so the poll
# registry does not count it. (Pacing first: the registry counts every poll.)
sleep(da.fetch('interval', 5) + 1)
rc, tok = token_post(client_id, key, { grant_type: GRANT, device_code: device_code }, assert: false)
results[:no_pop] = [rc, tok['error']]
rc, tok = token_post(client_id, key, { grant_type: GRANT, device_code: device_code })
abort "token poll failed: #{rc} #{tok}" unless rc == 200
token = tok.fetch('access_token')
# OAuth-pure response: identity rides inside the kiosk JWT claims.
claims = JWT.decode(token, nil, false).first
results[:bound_user] = claims['sub'] == HUMAN
# The role the binding carries is the APPROVER's, read from this origin's
# identity system when Alice approved — never anything the caller sent. Alice's
# User model defines no `#kiosk_role`, so kiosk-user-idp-devise answers the
# first declared role; that this origin declares exactly one is why the
# assertion is an equality rather than a distinction (see the note beside
# `c.roles` in fixtures/initializer_kiosk.rb).
results[:token_role] = claims['role']
agent_id = claims.fetch('agent_id')
results[:same_client] = agent_id == client_id

# Protocol verb as the bound assistant account — a query is a GET at its own path.
MY_APPOINTMENTS = "#{SERVER}/kiosk/my_appointments".freeze
# A call that carries a token carries a proof that its key signs for the call (RFC 9449).
def dpop(token, key, url) = Kiosk::TestHelpers::Dpop.headers(token, key, method: 'GET', url: url)

rc, q = get_json(MY_APPOINTMENTS, dpop(token, key, MY_APPOINTMENTS))
# The answer IS the rows, so "the protocol served it" is "a
# list came back", not "ok was true".
results[:wire_as_bound] = [rc, q.is_a?(Array)]

# The client_credentials grant is the refresh path for the bound client.
rc, refreshed = token_post(client_id, key, { grant_type: 'client_credentials' })
results[:token_bound] = [rc, rc == 200 && JWT.decode(refreshed.fetch('access_token'), nil, false).first['sub'] == HUMAN]

# ── link flow: the human mints a code, a second assistant redeems it ──
key2, client_id2 = registered_client
CLAIM_URL = "#{SERVER}/kiosk/auth/claim".freeze
rc, link = HUMAN_SESSION.post_json('/kiosk/auth/link', {}, { session: true })
results[:link_mint] = rc
rc, = post_json(CLAIM_URL, { code: link.fetch('link_code', '') }.merge(assertion_params(client_id2, key2, ISSUER)))
_, claimed = token_post(client_id2, key2, { grant_type: 'client_credentials' })
results[:link_claim] = [rc, JWT.decode(claimed.fetch('access_token', ''), nil, false).first['sub'] == HUMAN]
results[:tolls] = TOLLS.dup

# ── unlink the first assistant: registration-layer revocation ──
#
# Spec §6.3/§15.4 promise BOTH halves — "the client's tokens stop verifying AND
# the token endpoint refuses the client" — and this driver asserts both,
# because a watermark that is compared at one-second resolution has an aperture
# exactly one second wide and only the first half sees it. The token request is
# aligned to a wall-clock second boundary so the fresh token's `iat` lands in
# the SAME second as the unlink, then the refusal is asserted.
sleep(1.0 - (Time.now.to_f % 1.0) + 0.02)
rc, fresh = token_post(client_id, key, { grant_type: 'client_credentials' })
fresh_token = rc == 200 ? fresh.fetch('access_token') : token
rc, = HUMAN_SESSION.post_json('/kiosk/auth/unlink', { agent_id: agent_id }, { session: true })
results[:unlink] = rc

rc, = get_json(MY_APPOINTMENTS, dpop(token, key, MY_APPOINTMENTS))
results[:held_token_after_unlink] = rc
rc, = get_json(MY_APPOINTMENTS, dpop(fresh_token, key, MY_APPOINTMENTS))
results[:same_second_token_after_unlink] = rc
rc, refused = token_post(client_id, key, { grant_type: 'client_credentials' })
results[:token_after_unlink] = [rc, refused['error']]

# THE CODE, not only the status. A link code the origin does not know is spec
# §9.1 rule 2 -- an argument ADDRESSING something absent -- so it is
# `not_found` and specifically NOT `verb_not_found`, which is the other 404 in
# the vocabulary and means an unregistered verb NAME. This is the place in the
# harness that reaches an addressed-thing-absent 404 through a real client
# assertion, so it is where the second of the three refusal codes is exercised
# on a booted origin.
rc, unknown = post_json(CLAIM_URL, { code: "unknown-#{SecureRandom.hex(16)}" }.merge(assertion_params(client_id2, key2, ISSUER)))
results[:unknown_code_claim]      = rc
results[:unknown_code_claim_code] = unknown.is_a?(Hash) ? unknown['code'] : nil
results[:unknown_code_claim_type] = unknown.is_a?(Hash) ? unknown['type'] : nil

puts JSON.generate(results)
