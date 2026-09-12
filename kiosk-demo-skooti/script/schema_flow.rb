# frozen_string_literal: true

# Self-discovery proof driver — schema verb over HTTP.
#
# Registers a fresh agent through skooti's Equihash-tolled registration gate,
# calls `schema` (GET /kiosk/schema), prints one JSON line on stdout.
#
# NO (n, k) IS NAMED IN THIS COMMENT, ON PURPOSE. Naming one difficulty level's
# literal pair makes a line that KIOSK_POW_DIFFICULTY falsifies without an edit
# to this tree — a wrong claim reachable by an env var.
# `Kiosk::Pow::Equihash::Difficulty` is where a level's numbers live; quoting
# either pair back here, even in the past tense inside guillemets, also puts it
# in the way of a grep for live claims. The register step below prints the pair
# instead, read off the gate's own 402 — so on an origin whose register toll
# were switched off there would be no 402, no proof, and nothing here claiming
# otherwise.
#
# Usage (invoked by rake demo:schema — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3004 \
#   KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby script/schema_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any HTTP failure.

require "jwt"
require "json"
require "openssl"
require "securerandom"
require "uri"
require "kiosk/redteam/wire"

SERVER = ENV.fetch("SERVER_URL")

# One JSON-over-HTTP driver for the whole file. `kiosk-redteam` ships it, every
# demo already depends on that gem, and an adopter writing their own driver
# against this origin gets the same object off the shelf: `get_json`/`post_json`
# answer `[status, parsed_body]`, an unparseable body reads as `{}` so a text
# document can still be asserted on through `#get`, and an origin that refused
# the connection answers status 0 rather than raising.
WIRE = Kiosk::Redteam::Wire.new(base_url: SERVER)

# ── Register a fresh agent (Equihash PoW gate: 1 proof) ──────────────────────
#
# Only `equihash_solve` is taken from the shared helper; the handshake below is
# spelled out call by call, because this demo's whole subject is the toll and
# the 402 it reports is read here rather than swallowed inside a helper.
require_relative "equihash_register"  # for equihash_solve

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem

rc_ch, ch = WIRE.get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode(
  { aud: SERVER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key, "RS256",
)

# No proof COUNT here either: `registration_pow_count` is the server's, and
# the 402 below reports how many challenges it actually issued.
STDERR.puts "  Registering..."
reg_body = { public_key: pem, signed: pop }
rc, reg  = WIRE.post_json("/kiosk/auth/register", reg_body)
if rc == 402
  # The 402 is an RFC 9457 problem document since 0.4: `challenges` is a
  # TOP-LEVEL extension member, not nested under an `error` object.
  challenges = reg["challenges"]
  abort "402 without challenges[]: #{JSON.generate(reg)}" unless challenges.is_a?(Array) && challenges.any?

  # THE PARAMS ARE READ OFF THE WIRE, NEVER TYPED.  Every
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
  rc, reg = WIRE.post_json("/kiosk/auth/register", reg_body, { "Kiosk-PoW" => JSON.generate(proofs) })
end
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
token = reg.fetch("access_token")

# ── Call schema — UNAUTHENTICATED, and that IS the assertion ─────────────────
#
# `GET <endpoint>/schema` is PUBLIC: the catalogue holds no per-agent value and
# no secret, it is derived once at boot and served from memory, so gating it
# would buy nothing. Sending NO Authorization header here is what proves it — a
# 200 with the catalogue in the body is the whole test, and a regression to a
# gate would be a 401 the rake task reports.

schema_rc, schema_body = WIRE.get_json("/kiosk/schema")
abort "schema call failed (#{schema_rc}): #{JSON.generate(schema_body)}" unless schema_rc == 200

# ── /.well-known/kiosk.json — where the MODULE set lives ─────────────────────
#
# This document is the ONE place the module set is published. `schema` does not
# carry a second copy of it: `Array(config.capabilities)` is rendered here and
# nowhere else, so the property is asserted at its only home.
wk_rc, wk = WIRE.get_json("/.well-known/kiosk.json")
abort "kiosk.json failed (#{wk_rc})" unless wk_rc == 200
capabilities = wk.dig("kiosk", "capabilities") || []
STDERR.puts "  discovery capabilities=#{capabilities.inspect}"

# ── Emit structured JSON for the rake task to assert ────────────────────────

# `GET <endpoint>/schema` answers `{queries, actions}` DIRECTLY: no
# `{ok, kind, value}` envelope around them.
schema_value = schema_body || {}

puts JSON.generate({
  schema_status:          schema_rc,
  schema_queries:         schema_value["queries"],
  schema_actions:         schema_value["actions"],
  discovery_capabilities: capabilities,
})
