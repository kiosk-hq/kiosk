# frozen_string_literal: true

# Self-discovery proof driver — verifies the `schema` verb AND the discovery
# documents over HTTP, with the load-bearing NOT-ONLY-COMMERCE assertions.
#
# Boots against a running philslist server and calls, with NO credential at all:
#   GET /kiosk/schema
#   GET /.well-known/kiosk.json
#   GET /agents.json
#   GET /agents.txt
# and emits ONE JSON line the demo:schema rake task asserts on.
#
# The `pay`-absent proof reads the ONE self-description that carries the module
# set. `schema` published a byte-identical copy of it as `verbs` until T-095 —
# the same `Array(config.capabilities)` call, so it was one value under two
# names — and the field is gone. The honest assertion is therefore
# `capabilities == [schema, queries, actions]` in `/.well-known/kiosk.json`,
# and no payments block in agents.json / agents.txt.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3006 KIOSK_ISSUER=http://127.0.0.1:3006 \
#   bundle exec ruby script/schema_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on transport failure.

require "json"
require "net/http"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

def get(url, headers = {})
  uri = URI(url)
  req = Net::HTTP::Get.new(uri, headers)
  Net::HTTP.new(uri.host, uri.port).request(req)
end

def get_json(url, headers = {})
  res = get(url, headers)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── The schema verb — UNAUTHENTICATED, and that IS the assertion (T-094) ─────
#
# This call carried a Bearer token until 2026-08-19. `GET <endpoint>/schema` is
# PUBLIC now: the catalogue holds no per-agent value and no secret, it is
# derived once at boot and served from memory, so gating it bought nothing.
# Sending NO Authorization header is what proves it — a 200 with the catalogue
# in the body is the whole test, and a regression to the gate would be a 401.
rc, body = get_json("#{SERVER}/kiosk/schema")
abort "schema call failed (#{rc}): #{JSON.generate(body)}" unless rc == 200
# `GET <endpoint>/schema` answers `{queries, actions}` DIRECTLY — the 0.3
# `{ok, kind, value}` envelope was retired at the cutover, and `verbs` went in
# T-095: it rendered the same call `capabilities` renders, below.
schema_value = body || {}

# ── /.well-known/kiosk.json — the advertised capability set ──────────────────
wk_rc, wk = get_json("#{SERVER}/.well-known/kiosk.json")
abort "kiosk.json failed (#{wk_rc})" unless wk_rc == 200
capabilities = wk.dig("kiosk", "capabilities") || []
STDERR.puts "  discovery capabilities=#{capabilities.inspect}"

# ── agents.json — the payments block (must be absent) ────────────────────────
aj_rc, agents_json = get_json("#{SERVER}/agents.json")
abort "agents.json failed (#{aj_rc})" unless aj_rc == 200
agents_json_has_payments = agents_json.key?("payments")

# ── agents.txt — the AP2 / Payments directives (must be absent) ──────────────
at_res = get("#{SERVER}/agents.txt")
abort "agents.txt failed (#{at_res.code})" unless at_res.code.to_i == 200
agents_txt = at_res.body.to_s
agents_txt_has_ap2      = agents_txt.include?("Protocols: ap2")
agents_txt_has_payments = agents_txt.match?(/^Payments:/)

# ── Emit ONE JSON line for the rake task to assert ───────────────────────────
puts JSON.generate(
  schema_status:           rc,
  schema_queries:          schema_value["queries"],
  schema_actions:          schema_value["actions"],
  discovery_capabilities:  capabilities,
  agents_json_has_payments: agents_json_has_payments,
  agents_txt_has_ap2:       agents_txt_has_ap2,
  agents_txt_has_payments:  agents_txt_has_payments,
)
