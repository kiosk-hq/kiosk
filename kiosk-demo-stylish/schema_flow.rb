# frozen_string_literal: true

# Self-discovery proof driver — verifies the `schema` verb over HTTP.
#
# Boots against a running stylish server, authenticates with a StubIdp
# token (no RSA registration needed for the demo shape), calls:
#   GET /kiosk/schema
# and emits ONE JSON line the demo:schema rake task asserts on.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3001 \
#   KIOSK_ISSUER=http://127.0.0.1:3001 \
#   bundle exec ruby schema_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on transport failure.

require "json"
require "net/http"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

# Pre-seeded principal (see db/seeds.rb). StubIdp parses the token directly.
ALICE_UUID = "00000000-0000-0000-0000-000000000001"
TOKEN_A    = "agent:u-#{ALICE_UUID}:a-alice-schema:r-customer"

def get_json(url, headers = {})
  uri = URI(url)
  req = Net::HTTP::Get.new(uri, headers)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Call the schema verb ─────────────────────────────────────────────────────
rc, body = get_json(
  "#{SERVER}/kiosk/schema",
  { "Authorization" => "Bearer #{TOKEN_A}" },
)
abort "schema call failed (#{rc}): #{JSON.generate(body)}" unless rc == 200

schema_value = body["value"] || {}

STDERR.puts "  schema.verbs=#{(schema_value["verbs"] || []).inspect}"

# ── Emit ONE JSON line for the rake task to assert ───────────────────────────
puts JSON.generate(
  schema_status:  rc,
  schema_verbs:   schema_value["verbs"],
  schema_queries: schema_value["queries"],
  schema_actions: schema_value["actions"],
)
