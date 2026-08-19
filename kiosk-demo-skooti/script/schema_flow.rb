# frozen_string_literal: true

# Self-discovery proof driver — schema verb over HTTP.
#
# Registers a fresh agent (Equihash PoW n=96 k=5 — skooti registration
# gate), calls `schema` (GET /kiosk/schema), prints one JSON line on stdout.
#
# Usage (invoked by rake demo:schema — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3004 \
#   KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby script/schema_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any HTTP failure.

require "jwt"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

def post_json(path, body, bearer: nil, pow: nil)
  uri = URI("#{SERVER}#{path}")
  headers = { "Content-Type" => "application/json" }
  headers["Authorization"] = "Bearer #{bearer}" if bearer
  headers["Kiosk-PoW"] = pow if pow  # PoW proof rides in the header (ADR-0022)
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

require_relative "../lib/equihash_register"  # for equihash_solve

# ── Register a fresh agent (Equihash PoW gate: 1 proof) ──────────────────────

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem

rc_ch, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode(
  { aud: SERVER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key, "RS256",
)

STDERR.puts "  Registering (solving 1 Equihash PoW)..."
reg_body = { public_key: pem, signed: pop }
rc, reg  = post_json("/kiosk/auth/register", reg_body)
if rc == 402
  # The 402 is an RFC 9457 problem document since 0.4: `challenges` is a
  # TOP-LEVEL extension member, not nested under an `error` object.
  challenges = reg["challenges"]
  abort "402 without challenges[]: #{JSON.generate(reg)}" unless challenges.is_a?(Array) && challenges.any?
  proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
  rc, reg = post_json("/kiosk/auth/register", reg_body, pow: JSON.generate(proofs))
end
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
token = reg.fetch("access_token")

# ── Call schema — UNAUTHENTICATED, and that IS the assertion (T-094) ─────────
#
# This call carried a Bearer token until 2026-08-19. `GET <endpoint>/schema` is
# PUBLIC now: the catalogue holds no per-agent value and no secret, it is
# derived once at boot and served from memory, so gating it bought nothing.
# Sending NO Authorization header here is what proves it — a 200 with the
# catalogue in the body is the whole test, and a regression to the gate would
# be a 401 the rake task reports.

schema_rc, schema_body = get_json("/kiosk/schema")
abort "schema call failed (#{schema_rc}): #{JSON.generate(schema_body)}" unless schema_rc == 200

# ── /.well-known/kiosk.json — where the MODULE set lives (T-095) ─────────────
#
# `schema` published the module set too, as `verbs`, until 2026-08-19 — the
# same `Array(config.capabilities)` call this document renders, so it was one
# value under two names rather than two facts. The field is gone; the property
# it carried is asserted here, at its one remaining home.
wk_rc, wk = get_json("/.well-known/kiosk.json")
abort "kiosk.json failed (#{wk_rc})" unless wk_rc == 200
capabilities = wk.dig("kiosk", "capabilities") || []
STDERR.puts "  discovery capabilities=#{capabilities.inspect}"

# ── Emit structured JSON for the rake task to assert ────────────────────────

# `GET <endpoint>/schema` answers `{verbs, queries, actions}` DIRECTLY — the
# 0.3 `{ok, kind, value}` envelope was retired at the cutover (T-074 = A).
schema_value = schema_body || {}

puts JSON.generate({
  schema_status:          schema_rc,
  schema_queries:         schema_value["queries"],
  schema_actions:         schema_value["actions"],
  discovery_capabilities: capabilities,
})
