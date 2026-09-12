# frozen_string_literal: true

# Self-discovery proof driver — the schema verb over HTTP.
#
# Registers a fresh agent (registration IS PoW-gated; equihash_register
# solves it transparently), calls `schema`, prints one JSON line on stdout.
#
# Usage (invoked by rake demo:schema — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3001 \
#   KIOSK_ISSUER=http://127.0.0.1:3001 \
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

# ── Register a fresh agent (register PoW solved transparently) ───────────────
#
# `equihash_register` drives FULL URLs through the two callables it is handed —
# it is the one helper a driver shares with e2e, where the origin is not known
# until the harness boots it — while {WIRE} is bound to this origin, so the
# adapters below hand it the path.
require_relative "equihash_register"
_key, reg = equihash_register(
  server: SERVER, issuer: SERVER,
  get_json:  ->(url) { WIRE.get_json(url.delete_prefix(SERVER)) },
  post_json: ->(url, body, headers = {}) { WIRE.post_json(url.delete_prefix(SERVER), body, headers) },
)
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

# `GET <endpoint>/schema` answers `{verbs, queries, actions}` DIRECTLY, with no
# envelope around it.
schema_value = schema_body || {}

puts JSON.generate({
  schema_status:          schema_rc,
  schema_queries:         schema_value["queries"],
  schema_actions:         schema_value["actions"],
  discovery_capabilities: capabilities,
})
