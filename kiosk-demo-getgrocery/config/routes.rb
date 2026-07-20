# frozen_string_literal: true

Rails.application.routes.draw do
  # Human storefront + the agent hook ("Agents → Kiosk here") on the homepage.
  root "home#index"

  # Kiosk wire surface (controllers shipped by kiosk-server).
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

  # Account binding: the human half (verify page, link mint, unlink — the
  # stub user-session channel, see lib/stub_user_idp.rb) and the agent
  # half (link-code redeem). `rake demo:claim` walks the claim-rebind
  # ceremony: an already-registered assistant's key is re-bound to the
  # human's own account.
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

  # /.well-known/kiosk.json discovery endpoint — the machine-readable
  # HANDSHAKE: who/where/which version + issuer (the AP2 `iss` anchor) + auth,
  # served at the guessable conventional URL. It advertises `capabilities`,
  # the verb names actually served (schema/query/run/pay), computed from the
  # live registry, so discovery and the live surface never drift.
  get "/.well-known/kiosk.json",            to: "kiosk/server/discovery#kiosk_json"

  # /.well-known/api-catalog — RFC 9727 linkset of the live wire endpoints
  # (schema tagged service-desc), served by the same DiscoveryController.
  get "/.well-known/api-catalog",           to: "kiosk/server/discovery#api_catalog"

  # ─── Provider admin (read-only demo back-office) ──────────────────────────
  # No auth required — demo provider only. Production would authenticate.
  get "/admin/orders" => "admin/orders#index", as: :admin_orders

  # ─── Live-activity telemetry aggregate (T-032 §4, opt-in) ─────────────────
  # Privacy-safe counts the demo page + the kiosk.tech landing tile fetch.
  # Drawn ONLY when KIOSK_TELEMETRY=1 so it is a pure no-op in CI/local flows.
  if ENV["KIOSK_TELEMETRY"] == "1"
    get "/demo/activity.json", to: "demo_activity#show", defaults: { format: :json }
  end

  # ─── Stripe Checkout return page ──────────────────────────────────────────
  # The SetupIntent success_url (return_url in the initializer) lands the human
  # here after they save a card. Without this route the human hit a 404
  # post-card-entry (a demo gap this route closes). Production providers point at
  # kiosk.tech/payment/return; a self-hosted demo serves its own.
  get "/payment/return", to: ->(_env) {
    [200, { "content-type" => "text/html; charset=utf-8" },
     ["<!DOCTYPE html><html><head><meta charset='utf-8'><title>Card saved</title></head>" \
      "<body style='font-family:system-ui,sans-serif;text-align:center;padding:64px'>" \
      "<h1>Card saved ✓</h1><p>Your assistant can now pay on your behalf. " \
      "You can close this tab.</p>" \
      "<p style='color:#888;font-size:14px'>getgrocery · Stripe test mode</p>" \
      "</body></html>"]]
  }
end
