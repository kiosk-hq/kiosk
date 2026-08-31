# frozen_string_literal: true

require "kiosk/redteam"
require "webmock/rspec"

# ── The 0.4 wire, as the specs speak it ──────────────────────────────────────
#
# Every error on the Kiosk wire is an RFC 9457 problem document served as
# `application/problem+json`, and a problem document is FLAT:
#
#   { "type": "https://kiosk.tech/problems/<code>", "title": "…",
#     "status": 403, "detail": "…", "code": "…", "hint": "…" }
#
# `code` is a TOP-LEVEL extension member — it is THE branch point every verdict
# in this gem reads (Kiosk::Redteam.error_code). 0.3's `{ok:false, error:{code:}}`
# envelope was deleted with the endpoints that served it, so a stub that nests
# an `error` object makes `error_code` answer nil and the verdict it drives
# collapses silently. These helpers exist so no spec can write that shape by
# accident.

# Kiosk::Server::Errors::CODES — the closed vocabulary and the status each code
# canonically rides. A stub cannot invent a code/status pair the wire would
# never emit.
PROBLEM_STATUS = {
  "bad_request"            => 400,
  "unauthenticated"        => 401,
  "pow_required"           => 402,
  "payment_setup_required" => 402,
  "payment_failed"         => 402,
  "forbidden"              => 403,
  "rls_denied"             => 403,
  "spending_cap_exceeded"  => 403,
  "kyc_required"           => 403,
  "verb_not_found"         => 404,
  "not_found"              => 404,
  "method_not_allowed"     => 405,
  "conflict"               => 409,
  "quota_exceeded"         => 429,
  "action_failed"          => 500,
  "internal_error"         => 500,
  "module_not_served"      => 501,
}.freeze

# The ONE code a bare status carries by itself (Errors::STATUS_CODES), widened
# with the two 5xx/502/503 shapes a crashing origin renders. 402 is deliberately
# absent from the server's table — three codes share it — so a stub that means a
# 402 must name which one. 404 carries TWO codes since T-158 and stays mapped to
# `not_found` here for the same reason the server's table does: `verb_not_found`
# comes from the registry lookup, never from a bare status, so a stub meaning it
# names it.
STATUS_DEFAULT_CODE = {
  400 => "bad_request",
  401 => "unauthenticated",
  403 => "forbidden",
  404 => "not_found",
  405 => "method_not_allowed",
  409 => "conflict",
  422 => "bad_request",
  429 => "quota_exceeded",
  500 => "internal_error",
  502 => "internal_error",
  503 => "internal_error",
}.freeze

JSON_CONTENT_TYPE    = "application/json"
PROBLEM_CONTENT_TYPE = "application/problem+json"

# An RFC 9457 problem document for +code+. Extra keyword arguments become
# top-level EXTENSION MEMBERS — that is where `challenges` and `hint` live.
def problem(code, status: nil, detail: nil, **extensions)
  code = code.to_s
  {
    "type"   => "https://kiosk.tech/problems/#{code}",
    "title"  => code.tr("_", " ").capitalize,
    "status" => status || PROBLEM_STATUS.fetch(code),
    "detail" => detail || "#{code} (redteam spec stub)",
    "code"   => code,
  }.merge(extensions.transform_keys(&:to_s))
end

# WebMock `to_return` hash carrying a success payload VERBATIM — no envelope.
def json_return(status, body)
  { status: status, body: JSON.generate(body), headers: { "Content-Type" => JSON_CONTENT_TYPE } }
end

# WebMock `to_return` hash carrying a problem document.
def problem_return(code, status: nil, **extensions)
  http_status = status || PROBLEM_STATUS.fetch(code.to_s)
  { status:  http_status,
    body:    JSON.generate(problem(code, status: http_status, **extensions)),
    headers: { "Content-Type" => PROBLEM_CONTENT_TYPE } }
end

# One wire answer: a 2xx renders +body+ as-is, anything else renders the problem
# document for +code+ (defaulting to the code that status carries by itself).
def wire_return(status:, body: nil, code: nil)
  return json_return(status, body || {}) if status < 400

  problem_return(code || STATUS_DEFAULT_CODE.fetch(status), status: status)
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |c|
    c.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.warnings = false

  # WebMock: disallow real HTTP in specs by default.
  # Individual examples may re-enable using WebMock.allow_net_connect!
  config.before(:suite) { WebMock.disable_net_connect! }

  # Every registration now begins with a proof-of-possession challenge fetch
  # (GET /kiosk/auth/challenge). Stub it broadly so scenario/client specs only
  # have to stub the register POST; a specific example may still override this.
  config.before(:each) do
    stub_request(:get, %r{/kiosk/auth/challenge}).to_return(
      status:  200,
      body:    JSON.generate("challenge" => "test-nonce", "exp" => Time.now.to_i + 120),
      headers: { "Content-Type" => JSON_CONTENT_TYPE },
    )
  end
end
