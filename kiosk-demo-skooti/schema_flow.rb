# frozen_string_literal: true

# Self-discovery proof driver — schema + help verbs over HTTP.
#
# Registers a fresh agent (SHA256 PoW at difficulty=20 — skooti registration
# gate), calls `schema` and `help`, prints one JSON line on stdout.
#
# Usage (invoked by rake demo:schema — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3003 \
#   KIOSK_ISSUER=http://127.0.0.1:3003 \
#   bundle exec ruby schema_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any HTTP failure.

require "digest"
require "json"
require "net/http"
require "openssl"
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

# Replicates Kiosk::Server::ProofOfWork.leading_zero_bits exactly.
def leading_zero_bits(bytes)
  return 0 if bytes.empty?

  count = 0
  bytes.each_byte do |b|
    if b == 0
      count += 8
    else
      bit = 7
      bit -= 1 while bit >= 0 && b[bit] == 0
      count += (7 - bit)
      break
    end
  end
  count
end

# ── Register a fresh agent (PoW difficulty=20) ───────────────────────────────

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem

STDERR.puts "  Solving PoW (difficulty=20)..."
pow = 0
pow += 1 until leading_zero_bits(Digest::SHA256.digest("#{pem}.#{pow}")) >= 20
STDERR.puts "  PoW solved: pow=#{pow}"

rc, reg = post_json(
  "/kiosk/agents/register",
  { name: "hermes-schema", public_key: pem, role: "customer", pow: pow.to_s },
)
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
token = reg.fetch("access_token")

# ── Call schema ──────────────────────────────────────────────────────────────

schema_rc, schema_body = post_json("/kiosk/exec", { command: "schema" }, bearer: token)
abort "schema call failed (#{schema_rc}): #{JSON.generate(schema_body)}" unless schema_rc == 200

# ── Call help ────────────────────────────────────────────────────────────────

help_rc, help_body = post_json("/kiosk/exec", { command: "help" }, bearer: token)
abort "help call failed (#{help_rc}): #{JSON.generate(help_body)}" unless help_rc == 200

# ── Emit structured JSON for the rake task to assert ────────────────────────

schema_value = schema_body["value"] || {}
help_value   = help_body["value"] || {}

puts JSON.generate({
  schema_status:  schema_rc,
  schema_verbs:   schema_value["verbs"],
  schema_queries: schema_value["queries"],
  schema_actions: schema_value["actions"],
  help_status:    help_rc,
  help_text:      help_value["text"],
})
