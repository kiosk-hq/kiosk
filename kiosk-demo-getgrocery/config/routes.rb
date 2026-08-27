# frozen_string_literal: true

Rails.application.routes.draw do
  # Human sign-in (Devise) — the web session that approves assistant links.
  # The sessions controller is overridden ONLY to answer a JSON-shaped
  # `DELETE /users/sign_out` with a JSON courtesy body — deliberately NOT the
  # wire's RFC 9457 problem document, see the controller (K-1092) — instead of
  # a bodyless 401 (K-533); every other Devise behaviour is inherited untouched.
  devise_for :users, controllers: { sessions: "users/sessions" }

  # Human storefront + the agent hook ("Agents → Kiosk here") on the homepage.
  # Devise needs this as its post-sign-in destination too.
  root "home#index"

  # Kiosk wire surface (controllers shipped by kiosk-server).
  # REST endpoints: one per verb, HTTP method = semantics.
  get  "/kiosk/schema",                            to: "kiosk/server/wire#schema"
  # NO `POST /kiosk/query` or `POST /kiosk/run` — protocol 0.4 deleted the
  # multiplexed pair outright (T-074 = A). Every verb is its own endpoint; the
  # pair that serves them is drawn LAST, at the bottom of this file.
  post "/kiosk/pay",                               to: "kiosk/server/wire#pay"
  get  "/kiosk/.well-known/jwks.json",             to: "kiosk/server/jwks#show"
  post "/kiosk/oauth/device_authorization",        to: "kiosk/server/oauth_device_authorization#create"
  post "/kiosk/oauth/token",                       to: "kiosk/server/oauth_token#create"
  get  "/kiosk/auth/challenge",                     to: "kiosk/server/auth#challenge"
  post "/kiosk/auth/register",                      to: "kiosk/server/auth#register"
  post "/kiosk/auth/login",                         to: "kiosk/server/auth#login"
  post "/kiosk/auth/revoke",                        to: "kiosk/server/auth#revoke"

  # Account binding: the human half (verify page, link mint, unlink — the
  # real Devise session channel, kiosk-user-idp-devise) and the agent
  # half (link-code redeem). `rake demo:claim` walks the claim-rebind
  # ceremony: an already-registered assistant's key is re-bound to the
  # human's own account.
  get  "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#show"
  post "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#create"
  post "/kiosk/auth/link",                         to: "kiosk/server/auth#link"
  post "/kiosk/auth/claim",                        to: "kiosk/server/auth#claim"
  post "/kiosk/auth/unlink",                       to: "kiosk/server/auth#unlink"
  get  "/auth.md",                                 to: "kiosk/server/discovery#auth_md"

  # KYC attestation submit (engine controller) — the agent posts the
  # broker-signed age_over_18 claim here after kyc_status returns approved.
  post "/kiosk/agents/kyc",                        to: "kiosk/server/kyc_attestation#create"

  # KYC broker callback — the broker → operator leg. `run
  # request_kyc` calls the broker's intake with THIS callback; on the human's
  # approve, the broker POSTs the signed anonymized {age_over_18} claim here.
  # getgrocery verifies it against the trusted ProveKey, checks the
  # nonce/operator/request_id it stored, and parks the jws for the agent to
  # fetch via kyc_status and submit to /kiosk/agents/kyc.
  post "/kyc/callback",                            to: "kyc_callback#create"

  # Native discovery surface — served by kiosk-server's DiscoveryController
  # (rendered from Kiosk::Server::WellKnown, the single generator seam).
  # agents.txt / agents.json are ROOT-served per the agents.txt v1.0 standard.
  get "/agents.txt",                        to: "kiosk/server/discovery#agents_txt"
  get "/agents.json",                       to: "kiosk/server/discovery#agents_json"
  get "/.well-known/agent-configuration",   to: "kiosk/server/discovery#agent_configuration"

  # /.well-known/kiosk.json discovery endpoint — the machine-readable
  # HANDSHAKE: who/where/which version + issuer (the AP2 `iss` anchor) + auth,
  # served at the guessable conventional URL. It advertises `capabilities`,
  # the MODULES actually served (schema/queries/actions/pay), computed from the
  # live registry, so discovery and the live surface never drift. Never the
  # registered verb NAMES — a MODELLING rule, not a security one (spec 4.2):
  # GET /kiosk/schema is public, so there is nothing to withhold. This document
  # is a POINTER, the catalog is the CONTRACT, and a second copy of the verb
  # list would be a second source of truth for it.
  get "/.well-known/kiosk.json",            to: "kiosk/server/discovery#kiosk_json"

  # /.well-known/api-catalog — RFC 9727 linkset of the live wire endpoints
  # (schema tagged service-desc), served by the same DiscoveryController.
  get "/.well-known/api-catalog",           to: "kiosk/server/discovery#api_catalog"

  # /kiosk/openapi.json — the DERIVED OpenAPI description of the per-verb wire
  # (T-071 = C). It MUST be drawn above the per-verb pair: Rails appends
  # `(.:format)` to `/kiosk/:kiosk_verb`, so without this line the path reads as
  # the verb `openapi` in the `json` format and answers 404.
  get "/kiosk/openapi.json",                to: "kiosk/server/open_api#show"

  # ── The 0.4 per-verb wire ────────────────────────────────────────────────
  #
  # One endpoint per registered verb: GET /kiosk/<query-name>,
  # POST /kiosk/<action-name>. getgrocery hand-draws its routes rather than
  # mounting the engine (that IS the escape hatch the engine documents), so the
  # pair the engine would have drawn is written out here — and, like the
  # engine's, LAST, so every reserved line above wins by first-match and no
  # operator verb can shadow `schema`, `pay` or the auth plane.
  get  "/kiosk/:kiosk_verb", to: "kiosk/server/verb#show",
       constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
  post "/kiosk/:kiosk_verb", to: "kiosk/server/verb#create",
       constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }

  # ─── Provider admin (read-only demo back-office) ──────────────────────────
  # No auth required — demo provider only. Production would authenticate.
  get "/admin/orders" => "admin/orders#index", as: :admin_orders

  # ─── Live-activity telemetry aggregate (opt-in) ─────────────────
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
