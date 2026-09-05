# frozen_string_literal: true

# Self-discovery proof driver — verifies the `schema` verb over HTTP.
#
# Boots against a running stylish server and calls, with no credential at all:
#   GET /kiosk/schema            (unauthenticated — the catalogue is public)
#   GET /.well-known/kiosk.json  (the one document carrying the module set)
# and emits ONE JSON line the demo:schema rake task asserts on.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
#   bundle exec ruby script/schema_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on transport failure.

require "json"
require "net/http"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

def get_json(url, headers = {})
  uri = URI(url)
  req = Net::HTTP::Get.new(uri, headers)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Call schema — UNAUTHENTICATED, and that IS the assertion ─────────────────
#
# `GET <endpoint>/schema` is PUBLIC: the catalogue holds no per-agent value and
# no secret, it is derived once at boot and served from memory, so gating it
# would buy nothing. Sending NO Authorization header here is what proves it — a
# 200 with the catalogue in the body is the whole test, and a regression to a
# gate would be a 401 the rake task reports.
rc, body = get_json("#{SERVER}/kiosk/schema")
abort "schema call failed (#{rc}): #{JSON.generate(body)}" unless rc == 200

# `GET <endpoint>/schema` answers `{queries, actions}` DIRECTLY: no
# `{ok, kind, value}` envelope, and no `verbs` — that would only duplicate
# `capabilities` byte for byte.
schema_value = body || {}

# ── /.well-known/kiosk.json — where the MODULE set lives ─────────────────────
wk_rc, wk = get_json("#{SERVER}/.well-known/kiosk.json")
abort "kiosk.json failed (#{wk_rc})" unless wk_rc == 200
capabilities = wk.dig("kiosk", "capabilities") || []
STDERR.puts "  discovery capabilities=#{capabilities.inspect}"

# ── Emit ONE JSON line for the rake task to assert ───────────────────────────
puts JSON.generate(
  schema_status:          rc,
  schema_queries:         schema_value["queries"],
  schema_actions:         schema_value["actions"],
  discovery_capabilities: capabilities,
)
