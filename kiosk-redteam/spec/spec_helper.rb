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

# ── THE ERROR VOCABULARY IS READ OFF THE ENGINE, NEVER COPIED HERE ───────────
#
# Every verdict this gem reaches branches on `code`, and the specs that prove
# the branching stub the wire from the two tables below. A hand-typed copy of
# them would go green on a code the engine re-statuses or drops, while stubbing
# an answer the server can no longer send — so there is no copy: both tables are
# PARSED out of `kiosk-server/lib/kiosk/server/errors.rb` when this file loads.
#
# It is a SPEC-TIME textual read and not a dependency. This gem may not require
# `kiosk-server` — it speaks the wire from outside, which is the whole point of
# a red team — and reading a sibling's source at spec time costs it nothing at
# runtime. The read does NOT skip when the sibling is missing (K-502): a guard
# that goes quiet when its subject moves is worse than no guard, the specs are
# not shipped in the gemspec, and inside this monorepo the sibling is always
# there. If it is not, this raises and says which file it wanted.
KIOSK_ENGINE_ERRORS_RB =
  File.expand_path("../../kiosk-server/lib/kiosk/server/errors.rb", __dir__)

# Parse one frozen literal `NAME = { … }.freeze` table out of that file. Keys
# and values are each a quoted string or an integer, which is the whole of the
# grammar these two tables use. Every non-blank line inside the braces must
# parse: an under-match is the one failure this could suffer silently, so it is
# the one this refuses to return from. `path` is a seam for
# `engine_vocabulary_parity_spec.rb`, which points it at fixtures to prove each
# of the three raises is reachable.
def kiosk_engine_table(constant, path = KIOSK_ENGINE_ERRORS_RB)
  source = File.read(path)
  body   = source[/^[ \t]*#{constant} = \{$(.*?)^[ \t]*\}\.freeze$/m, 1]
  raise "#{constant} is not a frozen literal table in #{path}" if body.nil?

  lines = body.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
  pairs = lines.filter_map do |line|
    line.match(/\A(?:"([^"]+)"|(\d+))[ \t]*=>[ \t]*(?:"([^"]+)"|(\d+)),\z/)
  end
  raise "#{constant} parsed to nothing in #{path}" if pairs.empty?
  raise "#{constant} has #{lines.size - pairs.size} line(s) this parser cannot read" if pairs.size != lines.size

  pairs.to_h { |m| [m[1] || Integer(m[2]), m[3] || Integer(m[4])] }.freeze
end

# `Errors::CODES` — the closed vocabulary and the status each code canonically
# rides. A stub cannot invent a code/status pair the wire would never emit.
PROBLEM_STATUS = kiosk_engine_table("CODES")

# `Errors::STATUS_CODES` — the ONE code a bare status carries by itself. 402 is
# deliberately absent from it (three codes share 402), so a stub that means a
# 402 must name which one; 404 carries two codes since T-158 and the engine maps
# the bare status to `not_found`, because `verb_not_found` comes from the
# registry lookup rather than from a status.
ENGINE_STATUS_CODES = kiosk_engine_table("STATUS_CODES")

# What this gem adds to it, and the only thing here that is ours: the statuses a
# CRASHING origin renders, which the engine's table has no reason to carry
# because nothing in the engine chooses them.
CRASHING_ORIGIN_STATUS_CODES = {
  500 => "internal_error",
  502 => "internal_error",
  503 => "internal_error",
}.freeze

STATUS_DEFAULT_CODE = ENGINE_STATUS_CODES.merge(CRASHING_ORIGIN_STATUS_CODES).freeze

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
