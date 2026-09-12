# frozen_string_literal: true

# Self-discovery proof driver — the schema verb over HTTP.
#
# Boots against a running hoteling server and calls, with NO credential at
# all:
#   GET /kiosk/schema            (unauthenticated — the catalogue is public)
#   GET /.well-known/kiosk.json  (the one document carrying the module set)
# and prints one JSON line on stdout.
#
# Usage (invoked by rake demo:schema — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3003 \
#   KIOSK_ISSUER=http://127.0.0.1:3003 \
#   bundle exec ruby script/schema_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any HTTP failure.

require "json"
require "kiosk/redteam/wire"

SERVER = ENV.fetch("SERVER_URL")

# One JSON-over-HTTP driver for the whole file. `kiosk-redteam` ships it, every
# demo already depends on that gem, and an adopter writing their own driver
# against this origin gets the same object off the shelf: `get_json`/`post_json`
# answer `[status, parsed_body]`, an unparseable body reads as `{}` so a text
# document can still be asserted on through `#get`, and an origin that refused
# the connection answers status 0 rather than raising.
WIRE = Kiosk::Redteam::Wire.new(base_url: SERVER)

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
