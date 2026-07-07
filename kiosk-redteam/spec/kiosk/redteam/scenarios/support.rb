# frozen_string_literal: true

# Shared helpers for scenario specs.
#
# Included in all scenario specs via RSpec shared context.
# Provides:
#   - BASE_URL constant
#   - client   — Kiosk::Redteam::Client pointed at BASE_URL (WebMock)
#   - stub_register(n) — stub n successive /register calls
#   - stub_exec_run / stub_exec_query / stub_exec_pay
#   - blocked_response / breach_response helpers
#   - minimal Profile factories

require "openssl"
require "json"

BASE_URL = "http://kiosk.test"

# ── Stub builders ───────────────────────────────────────────────────────────

def reg_response(suffix)
  { status: 201,
    body: JSON.generate(
      "agent_id"     => "agent-#{suffix}",
      "user_id"      => "user-#{suffix}",
      "access_token" => "tok-#{suffix}",
    ),
    headers: { "Content-Type" => "application/json" } }
end

# Stub successive register calls; pass suffixes in order of expected calls.
def stub_registers(*suffixes)
  stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
    .to_return(*suffixes.map { |s| reg_response(s) })
end

def stub_kyc(status: 200)
  stub_request(:post, "#{BASE_URL}/kiosk/agents/kyc")
    .to_return(
      status:  status,
      body:    JSON.generate(status == 200 ? { "ok" => true } : { "error" => { "code" => "forbidden" } }),
      headers: { "Content-Type" => "application/json" },
    )
end

def stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
  stub_request(:post, "#{BASE_URL}/kiosk/exec")
    .with { |req| JSON.parse(req.body)["command"] == "run" }
    .to_return(
      status:  status,
      body:    JSON.generate(body),
      headers: { "Content-Type" => "application/json" },
    )
end

def stub_exec_query(status: 200, rows: [])
  stub_request(:post, "#{BASE_URL}/kiosk/exec")
    .with { |req| JSON.parse(req.body)["command"] == "query" }
    .to_return(
      status:  status,
      body:    JSON.generate({ "rows" => rows }),
      headers: { "Content-Type" => "application/json" },
    )
end

def stub_exec_pay(status: 200)
  stub_request(:post, "#{BASE_URL}/kiosk/exec")
    .with { |req| JSON.parse(req.body)["command"] == "pay" }
    .to_return(
      status:  status,
      body:    JSON.generate(status == 200 ? { "value" => { "payment_mandate_id" => "pm-1" } } : { "error" => { "code" => "forbidden" } }),
      headers: { "Content-Type" => "application/json" },
    )
end

# Stub exec to return the same response for any command.
def stub_exec_any(status:, body: nil)
  body ||= status >= 400 ? { "error" => { "code" => "forbidden" } } : { "value" => {} }
  stub_request(:post, "#{BASE_URL}/kiosk/exec")
    .to_return(
      status:  status,
      body:    JSON.generate(body),
      headers: { "Content-Type" => "application/json" },
    )
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
