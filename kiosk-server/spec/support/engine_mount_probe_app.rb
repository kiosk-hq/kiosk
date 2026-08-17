# frozen_string_literal: true

# The fresh-host probe behind spec/kiosk/server/engine_mount_spec.rb — run as
# a SUBPROCESS, never loaded into the RSpec process. It boots a real
# Rails::Application with kiosk-server loaded (so the engine's initializers
# run through the genuine boot path), then drives three route-set scenarios
# through the full Rack stack and prints one JSON report to stdout for the
# spec to assert on.
#
# Out-of-process on purpose: booting Rails inside the suite process mutates
# it globally — Rails.logger stops being nil (pop_verifier_spec's operator-log
# fallback relies on that), and loading the app's default middleware brings in
# ActionDispatch::Flash, whose Request#commit_flash then runs in every
# controller spec and rejects the plain-Hash `rack.session` fakes the HTML
# controller specs use. A subprocess is also the more faithful simulation:
# a fresh adopter's app boots in its own process, exactly like this.

require "bundler/setup"
require "json"
require "kiosk/server"
require "rack/mock"

class ProbeApp < Rails::Application
  config.eager_load = false
  config.hosts.clear
  config.secret_key_base = "engine-mount-probe"
  config.logger = Logger.new(IO::NULL)
end
Rails.application.initialize!

Kiosk.configure do |c|
  c.issuer      = "http://localhost"
  c.user_model  = "User"
  c.signing_key = Kiosk::Server::SigningKey.generate
end
# One verb, so this origin has a live capability set for the discovery
# documents to advertise. Declared the shipped way — a controller with the
# mixin, registering as its class body is read (T-081). `c.handlers` is not
# needed here: the engine's `to_prepare` rebuild already ran during
# `initialize!` above, and this probe has no reloader.
class ProbeCatalogController < ActionController::API
  include Kiosk::Query

  description "probe query"
  def ping = render(json: [])
end

# A stub distinguishable from the shipped DiscoveryController, so the winner
# of a double-draw is observable.
class HandDrawnController < ActionController::API
  def hand = render(plain: "HAND-DRAWN")
end

def request(method, path)
  env = Rack::MockRequest.env_for("http://localhost#{path}", method: method)
  status, headers, raw = Rails.application.call(env)
  body = +""
  raw.each { |chunk| body << chunk }
  raw.close if raw.respond_to?(:close)
  {
    "status"  => status,
    # Rack 3 downcases response header names; normalize anyway.
    "headers" => headers.to_h.transform_keys(&:downcase),
    "body"    => body,
  }
end

SURFACE = [
  ["GET",  "/agents.txt"],
  ["GET",  "/agents.json"],
  ["GET",  "/auth.md"],
  ["GET",  "/.well-known/agent-configuration"],
  ["GET",  "/.well-known/kiosk.json"],
  ["GET",  "/.well-known/api-catalog"],
  ["GET",  "/kiosk/schema"],
  ["POST", "/kiosk/query"],
  ["POST", "/kiosk/run"],
  ["POST", "/kiosk/pay"],
  ["GET",  "/kiosk/auth/challenge"],
  ["POST", "/kiosk/auth/register"],
  ["POST", "/kiosk/auth/login"],
  ["POST", "/kiosk/auth/revoke"],
  ["GET",  "/kiosk/.well-known/jwks.json"],
  ["POST", "/kiosk/agents/kyc"],
  ["POST", "/kiosk/oauth/device_authorization"],
  ["POST", "/kiosk/oauth/token"],
  ["GET",  "/kiosk/oauth/device/verify"],
  ["POST", "/kiosk/auth/link"],
  ["POST", "/kiosk/auth/claim"],
  ["POST", "/kiosk/auth/unlink"],
  ["GET",  "/kiosk/auth/assistants"],
  ["POST", "/kiosk/auth/assistants/link"],
  ["POST", "/kiosk/auth/assistants/update"],
  ["POST", "/kiosk/auth/assistants/unlink"],
].freeze

def surface_snapshot
  SURFACE.to_h { |method, path| ["#{method} #{path}", request(method, path)] }
end

report = {}

# Scenario 1 — the one-line adoption: mount is the only route the host draws.
# RouteSet#draw clears and re-finalizes, re-running routes.append blocks —
# the dev-mode reload semantics, so redrawing between scenarios is faithful.
Rails.application.routes.draw do
  mount Kiosk::Server::Engine => "/kiosk"
end
report["mounted"] = surface_snapshot
report["mounted"]["mounted_in?"] =
  Kiosk::Server::Engine.mounted_in?(Rails.application.routes)

# Scenario 2 — gem loaded but NOT mounted: must be inert (today's demos
# hand-draw every route and must keep working unchanged until T-057).
Rails.application.routes.draw {}
report["unmounted"] = {
  "GET /agents.txt"              => request("GET", "/agents.txt"),
  "GET /.well-known/kiosk.json"  => request("GET", "/.well-known/kiosk.json"),
  "GET /kiosk/schema"            => request("GET", "/kiosk/schema"),
  "mounted_in?"                  =>
    Kiosk::Server::Engine.mounted_in?(Rails.application.routes),
}

# Scenario 3 — host BOTH mounts and hand-draws the same paths (a
# half-migrated app): the hand-drawn line must win, everything else must
# still resolve through the mount.
Rails.application.routes.draw do
  get "/agents.txt",   to: "hand_drawn#hand"
  get "/kiosk/schema", to: "hand_drawn#hand"
  mount Kiosk::Server::Engine => "/kiosk"
end
report["double_draw"] = {
  "GET /agents.txt"                    => request("GET", "/agents.txt"),
  "GET /kiosk/schema"                  => request("GET", "/kiosk/schema"),
  "GET /agents.json"                   => request("GET", "/agents.json"),
  "GET /kiosk/.well-known/jwks.json"   => request("GET", "/kiosk/.well-known/jwks.json"),
}

puts JSON.generate(report)
