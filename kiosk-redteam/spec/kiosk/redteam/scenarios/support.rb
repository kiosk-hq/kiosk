# frozen_string_literal: true

# Shared helpers for scenario specs.
#
# ── The 0.4 per-verb wire ────────────────────────────────────────────────────
#
#   GET  <mount>/<query-name>?<args>   a query  — arguments in the QUERY STRING
#   POST <mount>/<action-name>         an action — the arguments ARE the body
#   POST <mount>/pay                   reserved, unchanged
#   POST <mount>/agents/kyc            reserved, unchanged
#   POST <mount>/auth/register         reserved, unchanged
#
# There is no `<mount>/query` and no `<mount>/run` — they were deleted at the
# cutover — and there is no `name` field anywhere: the verb name is a PATH
# SEGMENT, which is also what the PoW fingerprint binds to. A stub written
# against a `name` body field therefore matches nothing at all.
#
# SUCCESS has no envelope: a paginating query answers `{"rows": …, "next": …}`,
# a non-paginating one a BARE JSON ARRAY, and an action or `pay` answers its own
# object. ERRORS are RFC 9457 problem documents — see spec_helper's `problem`.
#
# Provides:
#   - BASE_URL constant + verb_url(name)
#   - stub_registers(*suffixes) — successive /auth/register calls
#   - stub_action / stub_query / stub_pay / stub_kyc
#   - minimal Profile factories

require "openssl"
require "json"

BASE_URL = "http://kiosk.test"

# The endpoint of one verb — its name IS the path segment.
def verb_url(name)
  "#{BASE_URL}/kiosk/#{name}"
end

# ── Stub builders ───────────────────────────────────────────────────────────

def reg_response(suffix)
  json_return(
    201,
    "agent_id"     => "agent-#{suffix}",
    "user_id"      => "user-#{suffix}",
    "access_token" => "tok-#{suffix}",
  )
end

# Stub successive register calls; pass suffixes in order of expected calls.
def stub_registers(*suffixes)
  stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
    .to_return(*suffixes.map { |s| reg_response(s) })
end

# POST <mount>/agents/kyc — a reserved endpoint the cutover did not touch.
# Success is the verifier's own object; a refusal is a problem document.
def stub_kyc(status: 200, code: nil)
  stub_request(:post, "#{BASE_URL}/kiosk/agents/kyc")
    .to_return(wire_return(status: status, code: code,
                           body: { "kyc_verified" => true, "attributes" => {} }))
end

# The default object an action answers with. An action's payload reaches the
# wire VERBATIM, so this is the whole body — there is no wrapper around it.
ACTION_OK = { "id" => "res-1" }.freeze

# POST <mount>/<action-name>. `args` are the body, so a stub that wants to
# assert them matches on the body directly.
def stub_action(name, status: 200, body: nil, code: nil)
  stub_request(:post, verb_url(name))
    .to_return(wire_return(status: status, body: body || ACTION_OK, code: code))
end

# One page of query rows: `{"rows": …, "next": <opaque cursor>}` — the answer a
# TRUNCATED paginating query gives (Kiosk::Server::Result#to_payload). This is
# the shape Scenario#rows_from reads.
def page(rows)
  { "rows" => rows, "next" => "b2Zmc2V0OjE" }
end

# GET <mount>/<query-name>. Scenario queries carry no arguments, so the URL is
# exact; a query WITH arguments is matched with `.with(query: …)`.
def stub_query(name, status: 200, rows: [], body: nil, code: nil)
  stub_request(:get, verb_url(name))
    .to_return(wire_return(status: status, body: body || page(rows), code: code))
end

# The settlement object `POST <mount>/pay` answers (Executor#pay).
PAY_OK = {
  "settlement_id"        => "stl-1",
  "psp_reference"        => "pi_test_1",
  "settled_amount_cents" => 100,
  "currency"             => "eur",
}.freeze

def stub_pay(status: 200, body: nil, code: nil)
  stub_request(:post, "#{BASE_URL}/kiosk/pay")
    .to_return(wire_return(status: status, body: body || PAY_OK, code: code))
end

# ── Minimal profile factories ───────────────────────────────────────────────

OWNED_REF = { id: "res-1", scooter_code: "SK-001" }.freeze

def minimal_profile(**overrides)
  Kiosk::Redteam::Profile.new(
    create_owned: ->(_client, _principal) { OWNED_REF.dup },
    **overrides,
  )
end

def now_ish
  Time.now.to_i
end

def pay_for_callable
  lambda do |_client, principal, owned_ref|
    t = now_ish
    {
      intent: {
        "id"               => "intent-#{SecureRandom.uuid rescue "x"}",
        "user_id"          => principal.user_id,
        "agent_id"         => principal.agent_id,
        "iss"              => "http://test.example",
        "scope"            => "test",
        "cap_amount_cents" => 1000,
        "currency"         => "eur",
        "exp"              => t + 600,
        "iat"              => t,
      },
      cart: {
        "id"                 => "cart-#{SecureRandom.uuid rescue "x"}",
        "intent_mandate_id"  => "intent-x",
        "user_id"            => principal.user_id,
        "agent_id"           => principal.agent_id,
        "iss"                => "http://test.example",
        "line_items"         => [{ "sku" => (owned_ref[:id] || "res-1"), "qty" => 1 }],
        "total_amount_cents" => 100,
        "currency"           => "eur",
        "exp"                => t + 600,
        "iat"                => t,
      },
    }
  end
end
