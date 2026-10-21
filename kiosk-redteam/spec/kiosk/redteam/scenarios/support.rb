# frozen_string_literal: true

# Shared helpers for scenario specs.
#
# ── The 0.4 per-verb wire ────────────────────────────────────────────────────
#
#   GET  <mount>/<query-name>?<args>   a query  — arguments in the QUERY STRING
#   POST <mount>/<action-name>         an action — the arguments ARE the body
#   POST <mount>/pay                   reserved, unchanged
#   POST <mount>/agents/kyc            reserved, unchanged
#   POST <mount>/oauth/register        reserved, unchanged
#   POST <mount>/oauth/token           reserved, unchanged
#
# There is no `<mount>/query` and no `<mount>/run` — they were deleted at the
# cutover — and there is no `name` field anywhere: the verb name is a PATH
# SEGMENT, which is also what the PoW fingerprint binds to. A stub written
# against a `name` body field therefore matches nothing at all.
#
# SUCCESS has no envelope, and since T-092 no second shape either: EVERY query
# answers a BARE JSON ARRAY (a truncated page says so in an RFC 8288 `Link`
# header, not in the body), and an action or `pay` answers its own object.
# ERRORS are RFC 9457 problem documents — see spec_helper's `problem`.
#
# Provides:
#   - BASE_URL constant + verb_url(name)
#   - stub_registers(*suffixes) — successive registrations and their tokens
#   - token_for(suffix) — the access token the stub issues to agent-<suffix>
#   - stub_action / stub_query / stub_pay / stub_kyc
#   - minimal Profile factories

require 'openssl'
require 'json'
require 'securerandom'

BASE_URL = 'http://kiosk.test'

# The endpoint of one verb — its name IS the path segment.
def verb_url(name)
  "#{BASE_URL}/kiosk/#{name}"
end

# ── Stub builders ───────────────────────────────────────────────────────────

def reg_response(suffix) = json_return(201, 'client_id' => "agent-#{suffix}")

# The access token of agent-<suffix>, for account user-<suffix>. Unsigned: no spec verifies it.
def token_for(suffix) = JWT.encode({ sub: "user-#{suffix}", agent_id: "agent-#{suffix}" }, nil, 'none')

# Stub successive registrations; pass suffixes in order of expected calls.
# The token endpoint answers the client that the client assertion names.
def stub_registers(*suffixes)
  stub_request(:post, "#{BASE_URL}/kiosk/oauth/register")
    .to_return(*suffixes.map { |s| reg_response(s) })
  stub_tokens
end

def stub_tokens
  stub_request(:post, "#{BASE_URL}/kiosk/oauth/token").to_return do |request|
    client_id = JWT.decode(URI.decode_www_form(request.body).to_h['client_assertion'], nil, false).first['sub']
    json_return(200, 'access_token' => token_for(client_id.delete_prefix('agent-')), 'token_type' => 'DPoP')
  end
end

# POST <mount>/agents/kyc — a reserved endpoint the cutover did not touch.
# Success is the verifier's own object; a refusal is a problem document.
def stub_kyc(status: 200, code: nil)
  stub_request(:post, "#{BASE_URL}/kiosk/agents/kyc")
    .to_return(wire_return(status: status, code: code,
                           body: { 'kyc_verified' => true, 'attributes' => {} }))
end

# The default object an action answers with. An action's payload reaches the
# wire VERBATIM, so this is the whole body — there is no wrapper around it.
ACTION_OK = { 'id' => 'res-1' }.freeze

# POST <mount>/<action-name>. `args` are the body, so a stub that wants to
# assert them matches on the body directly.
def stub_action(name, status: 200, body: nil, code: nil)
  stub_request(:post, verb_url(name))
    .to_return(wire_return(status: status, body: body || ACTION_OK, code: code))
end

# GET <mount>/<query-name>. Scenario queries carry no arguments, so the URL is
# exact; a query WITH arguments is matched with `.with(query: …)`. The default
# body is the bare array a query answers.
def stub_query(name, status: 200, rows: [], body: nil, code: nil)
  stub_request(:get, verb_url(name))
    .to_return(wire_return(status: status, body: body || rows, code: code))
end

# The settlement object `POST <mount>/pay` answers (Executor#pay).
PAY_OK = {
  'settlement_id' => 'stl-1',
  'psp_reference' => 'pi_test_1',
  'settled_amount_cents' => 100,
  'currency' => 'eur'
}.freeze

def stub_pay(status: 200, body: nil, code: nil)
  stub_request(:post, "#{BASE_URL}/kiosk/pay")
    .to_return(wire_return(status: status, body: body || PAY_OK, code: code))
end

# ── Minimal profile factories ───────────────────────────────────────────────

OWNED_REF = { id: 'res-1', scooter_code: 'SK-001' }.freeze

def minimal_profile(**overrides)
  Kiosk::Redteam::Profile.new(
    create_owned: ->(_client, _principal) { OWNED_REF.dup },
    **overrides
  )
end

# The key a test operator signs its checkouts with.
OPERATOR_KEY = OpenSSL::PKey.generate_key('ED25519')

# The checkout a test operator signs for +principal+ to pay +owned_ref+.
def pay_for_callable
  lambda do |_client, principal, owned_ref|
    JWT.encode({ iss: BASE_URL, sub: principal.user_id, iat: Time.now.to_i,
                 merchant: { id: BASE_URL, name: 'Test', website: BASE_URL }, currency: 'eur', total_amount_cents: 100,
                 line_items: [{ reservation_id: owned_ref[:id] || 'res-1' }, { qty: 1, price_cents: 100 }] },
               OPERATOR_KEY, 'EdDSA')
  end
end
