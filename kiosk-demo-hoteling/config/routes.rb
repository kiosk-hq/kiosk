# frozen_string_literal: true

Rails.application.routes.draw do

  # Public root page: what this demo is + live DOMAIN activity (booking counts
  # read from hoteling's own tables) + how an agent pokes the wire. api_only
  # app, but HomeController inherits ActionController::Base so HTML renders.
  root "home#index"

  # Account binding: the human half (verify page, link mint, unlink — the
  # stub user-session channel, see lib/stub_user_idp.rb) and the agent
  # half (link-code redeem). Routed so every URL the discovery documents
  # advertise resolves; the walkthrough demos live in stylish
  # (claim + link) and getgrocery (claim-rebind).
  get  "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#show"
  post "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#create"
  post "/kiosk/auth/link",                         to: "kiosk/server/auth#link"
  post "/kiosk/auth/claim",                        to: "kiosk/server/auth#claim"
  post "/kiosk/auth/unlink",                       to: "kiosk/server/auth#unlink"
  get  "/auth.md",                                 to: "kiosk/server/discovery#auth_md"
  # Kiosk wire surface (controllers shipped by kiosk-server).
  # In a follow-up release these will be mounted via the engine's own
  # routes drawer; for v0.1 alpha we wire them manually here.
  # REST endpoints: one per verb, HTTP method = semantics.
  get  "/kiosk/schema",                            to: "kiosk/server/wire#schema"
  post "/kiosk/query",                             to: "kiosk/server/wire#query"
  post "/kiosk/run",                               to: "kiosk/server/wire#run"
  post "/kiosk/pay",                               to: "kiosk/server/wire#pay"
  get  "/kiosk/.well-known/jwks.json",             to: "kiosk/server/jwks#show"
  post "/kiosk/oauth/device_authorization",        to: "kiosk/server/oauth_device_authorization#create"
  post "/kiosk/oauth/token",                       to: "kiosk/server/oauth_token#create"
  get  "/kiosk/auth/challenge",                     to: "kiosk/server/auth#challenge"
  post "/kiosk/auth/register",                      to: "kiosk/server/auth#register"
  post "/kiosk/auth/login",                         to: "kiosk/server/auth#login"
  post "/kiosk/auth/revoke",                        to: "kiosk/server/auth#revoke"

  # Native discovery surface — served by kiosk-server's DiscoveryController
  # (rendered from Kiosk::Server::WellKnown, the single generator seam).
  # agents.txt / agents.json are ROOT-served per the agents.txt v1.0 standard.
  get "/agents.txt",                        to: "kiosk/server/discovery#agents_txt"
  get "/agents.json",                       to: "kiosk/server/discovery#agents_json"
  get "/.well-known/agent-configuration",   to: "kiosk/server/discovery#agent_configuration"

  # /.well-known/kiosk.json discovery endpoint — served by the shipped
  # DiscoveryController (same WellKnown.build_json document).
  get "/.well-known/kiosk.json",            to: "kiosk/server/discovery#kiosk_json"

  # /.well-known/api-catalog — RFC 9727 linkset of the live wire endpoints
  # (schema tagged service-desc), served by the same DiscoveryController.
  get "/.well-known/api-catalog",           to: "kiosk/server/discovery#api_catalog"

  # ─── Live-activity telemetry aggregate (T-032 §4, opt-in) ─────────────────
  # Privacy-safe counts for the demo page + the kiosk.tech landing tile.
  # Drawn ONLY when KIOSK_TELEMETRY=1 so it is a no-op in CI/local flows.
  if ENV["KIOSK_TELEMETRY"] == "1"
    get "/demo/activity.json", to: "demo_activity#show", defaults: { format: :json }
  end
end
