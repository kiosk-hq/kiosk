# frozen_string_literal: true

# Self-discovery proof driver — verifies the `schema` verb over HTTP.
#
# Boots against a running stylish server and calls, with no credential at all:
#   GET /kiosk/schema            (unauthenticated — the catalogue is public)
#   GET /.well-known/kiosk.json  (the one document carrying the module set)
# and emits ONE JSON line the check:schema rake task asserts on.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
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

# ── Call schema — UNAUTHENTICATED, and that IS the assertion ─────────────────
#
# `GET <endpoint>/schema` is PUBLIC: the catalogue holds no per-agent value and
# no secret, it is derived once at boot and served from memory, so gating it
# would buy nothing. Sending NO Authorization header here is what proves it — a
# 200 with the catalogue in the body is the whole test, and a regression to a
# gate would be a 401 the rake task reports.
rc, body = WIRE.get_json("/kiosk/schema")
abort "schema call failed (#{rc}): #{JSON.generate(body)}" unless rc == 200

# `GET <endpoint>/schema` answers `{queries, actions}` DIRECTLY: no
# `{ok, kind, value}` envelope, and no `verbs` — that would only duplicate
# `capabilities` byte for byte.
schema_value = body || {}

# ── /.well-known/kiosk.json — where the MODULE set lives ─────────────────────
wk_rc, wk = WIRE.get_json("/.well-known/kiosk.json")
abort "kiosk.json failed (#{wk_rc})" unless wk_rc == 200
capabilities = wk.dig("kiosk", "capabilities") || []

# ── THE EVENT SURFACE ────────────────────────────────────────────────────────
#
# Read here, asserted in the rake task: this origin declares NO topic, so the
# module must be absent and the url unpublished — while the catalogue STILL
# carries an `events` array, empty. Present-and-empty rather than omitted is
# the point: a reader never has to branch on whether the member exists, and
# `capabilities` is the one place that answers whether it is served at all.
events_url        = wk.dig("kiosk", "events_url")
event_topic_names = ((schema_value || {})["events"] || []).map { |t| t["name"] }.sort
STDERR.puts "  discovery capabilities=#{capabilities.inspect}"

# ── Emit ONE JSON line for the rake task to assert ───────────────────────────
puts JSON.generate(
  schema_status:          rc,
  schema_queries:         schema_value["queries"],
  schema_actions:         schema_value["actions"],
  discovery_capabilities: capabilities,
  discovery_events_url:   events_url,
  schema_event_topics:    event_topic_names,
)
