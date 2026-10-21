# frozen_string_literal: true

require 'kiosk/redteam'
require 'webmock/rspec'

# Every error on the Kiosk wire is an RFC 9457 problem document served as
# `application/problem+json`, and a problem document is FLAT:
#
#   { "type": "https://kiosk.tech/problems/<code>", "title": "…",
#     "status": 403, "detail": "…", "code": "…", "hint": "…" }
#
# `code` is a top-level extension member, and every verdict in this gem
# branches on it (Kiosk::Redteam.error_code). A stub that nests an `error`
# object makes `error_code` answer nil. The helpers below write the flat shape.

# The error vocabulary is read from the engine source, not copied here: both
# tables below are parsed out of `kiosk-server/lib/kiosk/server/errors.rb` when
# this file loads. This is a spec-time text read, not a dependency; this gem
# speaks the wire from outside and does not require `kiosk-server`. When the
# file is missing the read raises and names the file; it does not skip.
KIOSK_ENGINE_ERRORS_RB =
  File.expand_path('../../kiosk-server/lib/kiosk/server/errors.rb', __dir__)

# One `key => value` line of a table: each side a quoted string or an integer.
ENGINE_TABLE_PAIR = /\A(?:'([^']+)'|(\d+))[ \t]*=>[ \t]*(?:'([^']+)'|(\d+)),?\z/

# Parses one frozen literal `NAME = { … }.freeze` table out of that file. Every
# non-blank line inside the braces must parse, so an under-match raises instead
# of returning a short table. `path` lets `engine_vocabulary_parity_spec.rb`
# point it at fixtures to reach each of the three raises.
def kiosk_engine_table(constant, path = KIOSK_ENGINE_ERRORS_RB)
  lines = kiosk_engine_table_lines(constant, path)
  pairs = lines.filter_map { |line| line.match(ENGINE_TABLE_PAIR) }
  raise "#{constant} parsed to nothing in #{path}" if pairs.empty?
  raise "#{constant} has #{lines.size - pairs.size} line(s) this parser cannot read" if pairs.size != lines.size

  pairs.to_h { |match| engine_table_entry(match) }.freeze
end

# A matched `key => value` line as [key, value], each a String or an Integer.
def engine_table_entry(match)
  [match[1] || Integer(match[2]), match[3] || Integer(match[4])]
end

# The non-blank, non-comment lines inside the braces of `NAME = { … }.freeze`.
def kiosk_engine_table_lines(constant, path)
  body = File.read(path)[/^[ \t]*#{constant} = \{$(.*?)^[ \t]*\}\.freeze$/m, 1]
  raise "#{constant} is not a frozen literal table in #{path}" if body.nil?

  body.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
end

# `Errors::CODES` — the closed vocabulary and the status each code canonically
# rides. A stub cannot invent a code/status pair the wire would never emit.
PROBLEM_STATUS = kiosk_engine_table('CODES')

# `Errors::STATUS_CODES` — the ONE code a bare status carries by itself. 402 is
# deliberately absent from it (three codes share 402), so a stub that means a
# 402 must name which one. 404 carries two codes, and the engine maps the bare
# status to `not_found`, because `verb_not_found` comes from the registry lookup
# rather than from a status.
ENGINE_STATUS_CODES = kiosk_engine_table('STATUS_CODES')

# What this gem adds to it, and the only thing here that is ours: the statuses a
# CRASHING origin renders, which the engine's table has no reason to carry
# because nothing in the engine chooses them.
CRASHING_ORIGIN_STATUS_CODES = {
  500 => 'internal_error',
  502 => 'internal_error',
  503 => 'internal_error'
}.freeze

STATUS_DEFAULT_CODE = ENGINE_STATUS_CODES.merge(CRASHING_ORIGIN_STATUS_CODES).freeze

JSON_CONTENT_TYPE    = 'application/json'
PROBLEM_CONTENT_TYPE = 'application/problem+json'

# An RFC 9457 problem document for +code+. Extra keyword arguments become
# top-level EXTENSION MEMBERS — that is where `challenges` and `hint` live.
def problem(code, status: nil, detail: nil, **extensions)
  code = code.to_s
  {
    'type' => "https://kiosk.tech/problems/#{code}",
    'title' => code.tr('_', ' ').capitalize,
    'status' => status || PROBLEM_STATUS.fetch(code),
    'detail' => detail || "#{code} (redteam spec stub)",
    'code' => code
  }.merge(extensions.transform_keys(&:to_s))
end

# WebMock `to_return` hash carrying a success payload VERBATIM — no envelope.
def json_return(status, body)
  { status: status, body: JSON.generate(body), headers: { 'Content-Type' => JSON_CONTENT_TYPE } }
end

# WebMock `to_return` hash carrying a problem document.
def problem_return(code, status: nil, **extensions)
  http_status = status || PROBLEM_STATUS.fetch(code.to_s)
  { status: http_status,
    body: JSON.generate(problem(code, status: http_status, **extensions)),
    headers: { 'Content-Type' => PROBLEM_CONTENT_TYPE } }
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
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.warnings = false

  # WebMock: disallow real HTTP in specs by default.
  # Individual examples may re-enable using WebMock.allow_net_connect!
  config.before(:suite) { WebMock.disable_net_connect! }
end
