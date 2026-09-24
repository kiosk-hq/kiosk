# frozen_string_literal: true

# Self-discovery proof driver — verifies the `schema` verb AND the discovery
# documents over HTTP, with the load-bearing NOT-ONLY-COMMERCE assertions.
#
# Boots against a running tudu server and calls, with NO credential at all:
#   GET /kiosk/schema
#   GET /.well-known/kiosk.json
#   GET /agents.json
#   GET /agents.txt
# and emits ONE JSON line the demo:schema rake task asserts on.
#
# The `pay`-absent proof reads the ONE self-description that carries the module
# set: `/.well-known/kiosk.json`. `schema` does not publish a second copy of it,
# so the honest assertion is `capabilities == [schema, queries, actions]` there,
# and no payments block in agents.json / agents.txt.
#
# Usage:
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby script/schema_flow.rb
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
# `GET <endpoint>/schema` answers `{queries, actions, events}` DIRECTLY: no
# `{ok, kind, value}` envelope, and no `verbs` — the module set is what
# `capabilities` renders, below.
schema_value = body || {}

# ── THE EVENT SURFACE ────────────────────────────────────────────────────────
#
# This flow SERVED the stream before it read anything about it: an origin could
# gain a whole module and the beat would not notice. What is read here is what
# an assistant actually reads — the topic NAMES in the catalogue, the closed
# member set of one descriptor, and the absence of the operator's own subject
# rule from a published document.
#
# THE ASSERTIONS ARE NOT HERE, and that is the split this file already has: the
# flow is shared by every demo that runs it, and what each origin SHOULD
# advertise differs. One that declares topics asserts the module is present;
# one that declares none asserts it is absent. Both read the same fields.
schema_events      = schema_value["events"] || []
event_topic_names  = schema_events.map { |t| t["name"] }.sort
todo_descriptor    = schema_events.find { |t| t["name"] == "todo" } || {}
todo_member_keys   = todo_descriptor.keys.sort

# ── /.well-known/kiosk.json — the advertised capability set ──────────────────
wk_rc, wk = WIRE.get_json("/.well-known/kiosk.json")
abort "kiosk.json failed (#{wk_rc})" unless wk_rc == 200
capabilities = wk.dig("kiosk", "capabilities") || []
events_url   = wk.dig("kiosk", "events_url")
STDERR.puts "  discovery capabilities=#{capabilities.inspect}"
STDERR.puts "  discovery events_url=#{events_url.inspect}"

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

# ── POSITIVE CONTROL: the two documents were actually READ ───────────────────
#
# Every flag above is an ABSENCE, and an absence is satisfied by an empty
# string exactly as well as by a document that carries no payment directive —
# on their own they cannot tell «this origin advertises no commerce» from
# «this driver read nothing». So each absence travels beside something the
# document DOES carry: agents.txt's byte count and its `Authorization:` line,
# agents.json's three v1.0 required keys. A blank read FAILS the beat.
agents_txt_bytes             = agents_txt.bytesize
agents_txt_has_authorization = agents_txt.match?(/^Authorization: agent-auth auth-md$/)
agents_json_keys             = agents_json.keys

# ── Emit ONE JSON line for the rake task to assert ───────────────────────────
puts JSON.generate(
  schema_status:                rc,
  schema_queries:               schema_value["queries"],
  schema_actions:               schema_value["actions"],
  discovery_capabilities:       capabilities,
  discovery_events_url:         events_url,
  schema_event_topics:          event_topic_names,
  schema_event_member_keys:     todo_member_keys,
  agents_json_has_payments:     agents_json_has_payments,
  agents_txt_has_ap2:           agents_txt_has_ap2,
  agents_txt_has_payments:      agents_txt_has_payments,
  agents_txt_bytes:             agents_txt_bytes,
  agents_txt_has_authorization: agents_txt_has_authorization,
  agents_json_keys:             agents_json_keys,
)
