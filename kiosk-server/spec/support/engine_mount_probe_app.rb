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
  include Kiosk::Handler

  kind :query
  description "probe query"
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def ping = render(json: [])
end

# A stub distinguishable from the shipped DiscoveryController, so the winner
# of a double-draw is observable. `boom` is the operator's own 500 — scenario 4
# drives it OUTSIDE the mount, where the Kiosk headers must NOT appear.
class HandDrawnController < ActionController::API
  def hand = render(plain: "HAND-DRAWN")
  def boom = raise("the operator's own code blew up")
end

# An agent-IdP that RAISES rather than returning nil. IdentityResolution's
# contract is "adapters return nil, they do not raise", so this is the shape of
# a real operator bug: the exception escapes WireController (whose `rescue_from`
# only covers Errors::Base), unwinds past every Kiosk seam and is rendered by
# Rails itself. Scenario 4 uses it to produce an unhandled 500 UNDER the mount
# through the engine's own controller — the second half of K-824.
class BlowingUpIdp
  def verify(_request) = raise("agent IdP adapter is broken")
end

# A Bearer token the bundled kiosk-pop IdP accepts: the probe configured the
# signing key and the issuer above, and DefaultAgentIdp#verify checks nothing
# else — no database is touched. It exists so the probe can reach a gate PAST
# `401`, which is the only way to tell "this path is the 0.3 wire" apart from
# "this path is an unregistered verb name" through the real Rack stack.
TOKEN = Kiosk::Server::JwtIssuer.issue(
  claims:   { sub: "u-1", agent_id: "a-1", actor: "agent" },
  audience: "http://localhost",
).freeze

def request(method, path, auth: false)
  env = Rack::MockRequest.env_for("http://localhost#{path}", method: method)
  env["HTTP_AUTHORIZATION"] = "Bearer #{TOKEN}" if auth
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

# The 0.3 multiplexed pair, dialed WITH a Bearer token (T-074 = A). Anonymous
# these two answer `401`, exactly like every other single-segment path under
# the mount — which proves nothing about whether the old wire is still there.
# Authenticated, the answer is the per-verb wire's ordinary `404 verb_not_found`
# for a name nobody registered, and that is the cut.
AUTHENTICATED = [
  ["POST", "/kiosk/query"],
  ["POST", "/kiosk/run"],
].freeze

def surface_snapshot
  snapshot = SURFACE.to_h { |method, path| ["#{method} #{path}", request(method, path)] }
  AUTHENTICATED.each do |method, path|
    snapshot["#{method} #{path} (bearer)"] = request(method, path, auth: true)
  end
  snapshot
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

# Scenario 4 — THE RESPONSES RAILS COMPOSES ITSELF (K-824). §3.6 binds every
# response under the mount "on success and on error alike", and the two it used
# to miss are the two that never return through an appended middleware: a
# routing 404 for a path the mount does not route, and an unhandled 500. Both
# are manufactured ABOVE the router by ActionDispatch::ShowExceptions /
# DebugExceptions, so this scenario is the only place in the suite where the
# stamp's POSITION in the stack — not its existence — is what is measured.
#
# The two host routes are the blast-radius control: the engine is mounted
# inside somebody else's application, and neither that application's working
# pages nor its own 500s may be stamped with Kiosk headers.
Rails.application.routes.draw do
  get "/outside",      to: "hand_drawn#hand"
  get "/outside/boom", to: "hand_drawn#boom"
  mount Kiosk::Server::Engine => "/kiosk"
end

previous_idp = Kiosk.configuration.agent_idp
report["exceptions"] = {
  # No engine route matches — two segments cannot be a verb name, so this
  # never reaches VerbController and stays a Rails routing 404.
  "GET /kiosk/nope/nope"  => request("GET", "/kiosk/nope/nope"),
  # The host's own 200 and the host's own 500, both outside the mount.
  "GET /outside"          => request("GET", "/outside"),
  "GET /outside/boom"     => request("GET", "/outside/boom"),
  # A root-level routing 404: outside the mount, so bare like the rest.
  "GET /nope"             => request("GET", "/nope"),
}
Kiosk.configure { |c| c.agent_idp = BlowingUpIdp.new }
begin
  # 500 UNDER the mount, raised inside the engine's own controller.
  report["exceptions"]["POST /kiosk/pay"] = request("POST", "/kiosk/pay")
ensure
  Kiosk.configure { |c| c.agent_idp = previous_idp }
end

puts JSON.generate(report)
