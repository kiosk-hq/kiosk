# frozen_string_literal: true

Rails.application.routes.draw do
  # Kiosk wire surface (controllers shipped by kiosk-server).
  # REST endpoints — HTTP method carries semantics (GET = read, POST = write).
  get  "/kiosk/schema",                             to: "kiosk/server/wire#schema"
  post "/kiosk/query",                              to: "kiosk/server/wire#query"
  post "/kiosk/run",                                to: "kiosk/server/wire#run"
  post "/kiosk/pay",                                to: "kiosk/server/wire#pay"
  get  "/kiosk/auth/challenge",                     to: "kiosk/server/auth#challenge"
  post "/kiosk/auth/register",                      to: "kiosk/server/auth#register"
  post "/kiosk/auth/login",                         to: "kiosk/server/auth#login"
  post "/kiosk/auth/revoke",                        to: "kiosk/server/auth#revoke"
  get  "/kiosk/.well-known/jwks.json",              to: "kiosk/server/jwks#show"
  post "/kiosk/oauth/device_authorization",        to: "kiosk/server/oauth_device_authorization#create"
  post "/kiosk/oauth/token",                       to: "kiosk/server/oauth_token#create"

  # Account binding: the human half (verify page, link mint, unlink — session
  # channel) and the agent half (link-code redeem).
  get  "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#show"
  post "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#create"
  post "/kiosk/auth/link",                         to: "kiosk/server/auth#link"
  post "/kiosk/auth/claim",                        to: "kiosk/server/auth#claim"
  post "/kiosk/auth/unlink",                       to: "kiosk/server/auth#unlink"
  get  "/auth.md",                                 to: "kiosk/server/discovery#auth_md"

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

  # ── The 0.4 per-verb wire (T-068 slice 1) ────────────────────────────────
  #
  # One endpoint per registered verb: GET /kiosk/<query-name>,
  # POST /kiosk/<action-name>. This origin hand-draws its routes rather than
  # mounting the engine (that IS the escape hatch the engine documents), so
  # the pair the engine would have drawn is written out here — and, like the
  # engine's, LAST, so every reserved line above wins by first-match and no
  # operator verb can shadow `schema`, `query`, `run`, `pay` or the auth
  # plane.
  get  "/kiosk/:kiosk_verb", to: "kiosk/server/verb#show",
       constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
  post "/kiosk/:kiosk_verb", to: "kiosk/server/verb#create",
       constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
end
