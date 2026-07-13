# frozen_string_literal: true

Rails.application.routes.draw do
  # Human storefront + the agent hook ("Agents → Kiosk here") on the homepage.
  root "home#index"

  # Kiosk wire surface (controllers shipped by kiosk-server).
  # REST endpoints (ADR-0005): one per verb, HTTP method = semantics.
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

  # /.well-known/kiosk.json discovery endpoint — built on the fly from
  # Kiosk.configuration. Inlined here since kiosk-server doesn't yet
  # ship a controller for it.
  # well-known = the machine-readable HANDSHAKE: who/where/which version + issuer
  # (the AP2 `iss` anchor) + auth, served at the guessable conventional URL. It
  # is NOT the surface — it advertises `capabilities`, the verb names actually
  # served (schema/query/run/pay), computed from the live registry (ADR-0009),
  # so discovery and the live surface never drift.
  get "/.well-known/kiosk.json", to: ->(env) {
    base_url = "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}"
    [200, { "content-type" => "application/json" },
     [Kiosk::Server::WellKnown.build_json(base_url: base_url)]]
  }

  # ─── Provider admin (read-only demo back-office) ──────────────────────────
  # No auth required — demo provider only. Production would authenticate.
  get "/admin/orders" => "admin/orders#index", as: :admin_orders
end
