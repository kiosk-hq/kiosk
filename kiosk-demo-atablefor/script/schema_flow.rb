# frozen_string_literal: true

# Self-discovery proof driver — verifies the `schema` verb AND the discovery
# documents over HTTP, with the load-bearing NOT-ONLY-COMMERCE assertions.
#
# Boots against a running atablefor server and calls, with NO credential at all:
#   GET /kiosk/schema
#   GET /.well-known/kiosk.json
#   GET /agents.json
#   GET /agents.txt
# and emits ONE JSON line the demo:schema rake task asserts on.
#
# The `pay`-absent proof reads the ONE self-description that carries the module
# set: `/.well-known/kiosk.json`. `schema` does not publish a second copy of it,
# so the honest assertion is `capabilities == [schema, queries, actions]` there,
# and no payments block in agents.json / agents.txt. atablefor books tables — a
# reservation takes no money.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3002 KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby script/schema_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on transport failure.

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

# ── The schema verb — UNAUTHENTICATED, and that IS the assertion ─────────────
#
# `GET <endpoint>/schema` is PUBLIC: the catalogue holds no per-agent value and
# no secret, it is derived once at boot and served from memory, so gating it
# would buy nothing. Sending NO Authorization header is what proves it — a 200
# with the catalogue in the body is the whole test, and a regression to a gate
# would be a 401.
rc, body = WIRE.get_json("/kiosk/schema")
abort "schema call failed (#{rc}): #{JSON.generate(body)}" unless rc == 200
# `GET <endpoint>/schema` answers `{queries, actions}` DIRECTLY: no
# `{ok, kind, value}` envelope, and no `verbs` — the module set is what
# `capabilities` renders, below.
schema_value = body || {}

# ── /.well-known/kiosk.json — the advertised capability set ──────────────────
wk_rc, wk = WIRE.get_json("/.well-known/kiosk.json")
abort "kiosk.json failed (#{wk_rc})" unless wk_rc == 200
capabilities = wk.dig("kiosk", "capabilities") || []
STDERR.puts "  discovery capabilities=#{capabilities.inspect}"

# ── agents.json — the payments block (must be absent) ────────────────────────
aj_rc, agents_json = WIRE.get_json("/agents.json")
abort "agents.json failed (#{aj_rc})" unless aj_rc == 200
agents_json_has_payments = agents_json.key?("payments")

# ── agents.txt — the AP2 / Payments directives (must be absent) ──────────────
at_res = WIRE.get("/agents.txt")
abort "agents.txt failed (#{at_res.status})" unless at_res.status == 200
agents_txt = at_res.raw_body
agents_txt_has_ap2      = agents_txt.include?("Protocols: ap2")
agents_txt_has_payments = agents_txt.match?(/^Payments:/)

# ── Emit ONE JSON line for the rake task to assert ───────────────────────────
puts JSON.generate(
  schema_status:            rc,
  schema_queries:           schema_value["queries"],
  schema_actions:           schema_value["actions"],
  discovery_capabilities:   capabilities,
  agents_json_has_payments: agents_json_has_payments,
  agents_txt_has_ap2:       agents_txt_has_ap2,
  agents_txt_has_payments:  agents_txt_has_payments,
)
