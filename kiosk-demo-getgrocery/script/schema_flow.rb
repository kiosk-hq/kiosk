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
require "net/http"
require "openssl"
require "securerandom"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

def get_json(path, bearer: nil)
  uri = URI("#{SERVER}#{path}")
  headers = {}
  headers["Authorization"] = "Bearer #{bearer}" if bearer
  req = Net::HTTP::Get.new(uri, headers)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Register a fresh agent (register PoW solved transparently) ───────────────
#
# This file defines only a `get_json`, and it takes a `bearer:` kwarg and a
# relative path, not the (url, body, headers) shape the shared helper drives;
# give it full-URL adapter lambdas that carry an arbitrary headers hash (the
# register retry rides the Kiosk-PoW header).
require_relative "equihash_register"
helper_get = ->(url) {
  uri = URI(url)
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
}
helper_post = ->(url, body, headers = {}) {
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
}
_key, reg = equihash_register(
  server: SERVER, issuer: SERVER,
  get_json: helper_get, post_json: helper_post,
)
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
# 0.3 `{ok, kind, value}` envelope was retired at the cutover.
schema_value = schema_body || {}

puts JSON.generate({
  schema_status:          schema_rc,
  schema_queries:         schema_value["queries"],
  schema_actions:         schema_value["actions"],
  discovery_capabilities: capabilities,
})
