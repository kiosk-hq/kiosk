# frozen_string_literal: true

# Self-discovery proof driver — the schema verb over HTTP.
#
# Registers a fresh agent (hoteling has no PoW gate — a single POST suffices),
# calls `schema` (GET /kiosk/schema), prints one JSON line on stdout.
#
# Usage (invoked by rake demo:schema — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3004 \
#   KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby schema_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any HTTP failure.

require "jwt"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

def post_json(path, body, bearer: nil)
  uri = URI("#{SERVER}#{path}")
  headers = { "Content-Type" => "application/json" }
  headers["Authorization"] = "Bearer #{bearer}" if bearer
  req = Net::HTTP::Post.new(uri, headers)
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path, bearer: nil)
  uri = URI("#{SERVER}#{path}")
  headers = {}
  headers["Authorization"] = "Bearer #{bearer}" if bearer
  req = Net::HTTP::Get.new(uri, headers)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Register a fresh agent (no PoW for hoteling) ──────────────────────────────

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem

STDERR.puts "  Registering agent (no PoW)..."

rc_ch, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode(
  { aud: SERVER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key, "RS256",
)
rc, reg = post_json(
  "/kiosk/auth/register",
  { public_key: pem, signed: pop },
)
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
token = reg.fetch("access_token")
STDERR.puts "  Registered: user_id=#{reg["user_id"]}"

# ── Call schema (GET /kiosk/schema — REST verb) ──────────────────────────────

schema_rc, schema_body = get_json("/kiosk/schema", bearer: token)
abort "schema call failed (#{schema_rc}): #{JSON.generate(schema_body)}" unless schema_rc == 200

# ── Emit structured JSON for the rake task to assert ────────────────────────

schema_value = schema_body["value"] || {}

puts JSON.generate({
  schema_status:  schema_rc,
  schema_verbs:   schema_value["verbs"],
  schema_queries: schema_value["queries"],
  schema_actions: schema_value["actions"],
})
