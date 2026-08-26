# frozen_string_literal: true

# Self-discovery proof driver — schema verb over HTTP.
#
# Registers a fresh agent through skooti's Equihash-tolled registration gate,
# calls `schema` (GET /kiosk/schema), prints one JSON line on stdout.
#
# NO (n, k) IS NAMED IN THIS COMMENT (K-1035 class). It used to read
# «Equihash PoW n=96 k=5», which KIOSK_POW_DIFFICULTY=high moves to 168/7
# without an edit to this tree — a false line reachable by an env var. The
# register step below prints the pair instead, read off the gate's own 402 —
# so on an origin whose register toll were switched off there would be no 402,
# no proof, and nothing here claiming otherwise.
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

# ── Register a fresh agent (Equihash PoW gate: 1 proof) ──────────────────────
#
# Only `equihash_solve` is taken from the shared helper; the handshake below is
# hand-rolled, for the reason both siblings state verbatim (K-712j): this file's
# get_json/post_json take a `bearer:` kwarg and relative paths, not the
# (url, body, headers) shape `equihash_register` drives. getgrocery and hoteling
# answer that by handing the helper full-URL adapter lambdas; this copy inlines
# the four calls instead, and either is fine — what was missing was saying so.
require_relative "equihash_register"  # for equihash_solve

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem

rc_ch, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode(
  { aud: SERVER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key, "RS256",
)

# No proof COUNT here either: `registration_pow_count` is the server's, and
# the 402 below reports how many challenges it actually issued.
STDERR.puts "  Registering..."
reg_body = { public_key: pem, signed: pop }
rc, reg  = post_json("/kiosk/auth/register", reg_body)
if rc == 402
  # The 402 is an RFC 9457 problem document since 0.4: `challenges` is a
  # TOP-LEVEL extension member, not nested under an `error` object.
  challenges = reg["challenges"]
  abort "402 without challenges[]: #{JSON.generate(reg)}" unless challenges.is_a?(Array) && challenges.any?

  # K-1035 class — THE PARAMS ARE READ OFF THE WIRE, NEVER TYPED.  Every
  # challenge the gate issues carries its own `params`
  # (Kiosk::Reputation::Challenge.issue → {id:, alg:, params:, salt:, exp:, sig:}),
  # so this is the (n, k) THIS server demanded of THIS request.  That is
  # strictly stronger than the driver-env read skooti's redteam header has to
  # make: it assumes nothing about the harness handing one environment to both
  # processes, and it follows KIOSK_POW_DIFFICULTY, an operator override, or a
  # per-identity policy alike.  The alg and the proof COUNT come from the same
  # place, so nothing on this line can outlive the thing it describes.
  demanded = challenges.first["params"] || {}
  STDERR.puts "  402 → solving #{challenges.size} #{challenges.first["alg"]} proof(s) " \
              "at n=#{demanded["n"]} k=#{demanded["k"]} (server-demanded)"

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
