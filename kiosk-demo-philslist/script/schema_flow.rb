# frozen_string_literal: true

# Self-discovery proof driver — verifies the `schema` verb AND the discovery
# documents over HTTP, with the load-bearing NOT-ONLY-COMMERCE assertions.
#
# Boots against a running philslist server, authenticates with a StubIdp token,
# calls:
#   GET /kiosk/schema
#   GET /.well-known/kiosk.json
#   GET /agents.json
#   GET /agents.txt
# and emits ONE JSON line the demo:schema rake task asserts on.
#
# The `pay`-absent proof is against the DISCOVERY documents, NOT schema.verbs:
# the schema verb's `verbs` field is the FIXED four-verb wire surface
# (Kiosk::Server::Executor::VERBS = [query, run, pay, schema]) and lists `pay`
# unconditionally. The advertised capability set is what drops `pay` when no
# payment_provider is configured — so the honest assertion is
# `/.well-known/kiosk.json` capabilities == [schema, query, run], and no
# payments block in agents.json / agents.txt.
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

# Pre-seeded principal (see db/seeds.rb). StubIdp parses the token directly.
ALICE_UUID = "00000000-0000-0000-0000-000000000001"
TOKEN_A    = "agent:u-#{ALICE_UUID}:a-alice-schema:r-customer"

def get(url, headers = {})
  uri = URI(url)
  req = Net::HTTP::Get.new(uri, headers)
  Net::HTTP.new(uri.host, uri.port).request(req)
end

def get_json(url, headers = {})
  res = get(url, headers)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── The schema verb ─────────────────────────────────────────────────────────
rc, body = get_json("#{SERVER}/kiosk/schema", { "Authorization" => "Bearer #{TOKEN_A}" })
abort "schema call failed (#{rc}): #{JSON.generate(body)}" unless rc == 200
schema_value = body["value"] || {}
STDERR.puts "  schema.verbs=#{(schema_value['verbs'] || []).inspect}"

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
  schema_verbs:            schema_value["verbs"],
  schema_queries:          schema_value["queries"],
  schema_actions:          schema_value["actions"],
  discovery_capabilities:  capabilities,
  agents_json_has_payments: agents_json_has_payments,
  agents_txt_has_ap2:       agents_txt_has_ap2,
  agents_txt_has_payments:  agents_txt_has_payments,
)
