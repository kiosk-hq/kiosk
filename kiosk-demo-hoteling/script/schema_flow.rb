# frozen_string_literal: true

# Self-discovery proof driver — the schema verb over HTTP.
#
# Registers a fresh agent (registration IS PoW-gated; equihash_register
# solves it transparently), calls `schema` (GET /kiosk/schema), prints one
# JSON line on stdout.
#
# Usage (invoked by rake demo:schema — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3003 \
#   KIOSK_ISSUER=http://127.0.0.1:3003 \
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

def post_json(path, body, bearer: nil)
  uri = URI("#{SERVER}#{path}")
  headers = { "Content-Type" => "application/json" }
  headers["Authorization"] = "Bearer #{bearer}" if bearer
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

# ── Register a fresh agent (register PoW solved transparently) ───────────────
#
# This file's post_json/get_json take a `bearer:` kwarg and relative paths, not
# the (url, body, headers) shape the shared helper drives; give it full-URL
# adapter lambdas that carry an arbitrary headers hash (the register retry rides
# the Kiosk-PoW header).
require_relative "../lib/equihash_register"

STDERR.puts "  Registering agent (solving the register PoW if the provider gates it)..."

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
STDERR.puts "  Registered: user_id=#{reg["user_id"]}"

# ── Call schema (GET /kiosk/schema — REST verb) ──────────────────────────────

schema_rc, schema_body = get_json("/kiosk/schema", bearer: token)
abort "schema call failed (#{schema_rc}): #{JSON.generate(schema_body)}" unless schema_rc == 200

# ── Emit structured JSON for the rake task to assert ────────────────────────

schema_value = schema_body["value"] || {}

puts JSON.generate({
  schema_status:  schema_rc,
  schema_verbs:   schema_value["verbs"],
  schema_queries: schema_value["queries"],
  schema_actions: schema_value["actions"],
})
