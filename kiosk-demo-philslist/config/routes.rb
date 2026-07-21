# frozen_string_literal: true

Rails.application.routes.draw do
  # Kiosk wire surface (controllers shipped by kiosk-server).
  # In a follow-up release these will be mounted via the engine's own
  # routes drawer; for v0.1 alpha we wire them manually here.
  get  "/kiosk/schema",                            to: "kiosk/server/wire#schema"
  post "/kiosk/query",                             to: "kiosk/server/wire#query"
  post "/kiosk/run",                               to: "kiosk/server/wire#run"
  # NO `POST /kiosk/pay` route — philslist takes no payments (the whole point).
  # Its absence is deliberate and part of the not-only-commerce proof.
  # Proof-of-possession auth surface (used by the registration-PoW demo).
  get  "/kiosk/auth/challenge",                    to: "kiosk/server/auth#challenge"
  post "/kiosk/auth/register",                     to: "kiosk/server/auth#register"
  post "/kiosk/auth/login",                        to: "kiosk/server/auth#login"
  post "/kiosk/auth/revoke",                       to: "kiosk/server/auth#revoke"
  get  "/kiosk/.well-known/jwks.json",             to: "kiosk/server/jwks#show"
  post "/kiosk/oauth/device_authorization",        to: "kiosk/server/oauth_device_authorization#create"
  post "/kiosk/oauth/token",                       to: "kiosk/server/oauth_token#create"

  # Account binding: the human half (verify page, link mint, unlink — the
  # Devise session channel) and the agent half (link-code redeem). Walked
  # end-to-end by `rake demo:binding`.
  get  "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#show"
  post "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#create"
  post "/kiosk/auth/link",                         to: "kiosk/server/auth#link"
  post "/kiosk/auth/claim",                        to: "kiosk/server/auth#claim"
  post "/kiosk/auth/unlink",                       to: "kiosk/server/auth#unlink"
  get  "/auth.md",                                 to: "kiosk/server/discovery#auth_md"

  # «Manage assistants» HTML page (kiosk-server AssistantsController): a
  # signed-in account holder lists their bound assistants, mints link codes,
  # unlinks, and edits per-assistant label + spending cap.
  get  "/kiosk/auth/assistants",                   to: "kiosk/server/assistants#show"
  post "/kiosk/auth/assistants/link",              to: "kiosk/server/assistants#link"
  post "/kiosk/auth/assistants/unlink",            to: "kiosk/server/assistants#unlink"
  post "/kiosk/auth/assistants/update",            to: "kiosk/server/assistants#update"

  # Human sign-in (Devise) — the web session that approves assistant links.
  devise_for :users

  # Public root page: what this demo is + live DOMAIN activity (listing counts
  # read from philslist's own tables) + both doors (human sign-in + the Kiosk
  # wire). The board itself is still read/written over the wire (browse_listings
  # / post_listing) — this page is informational + live-stats, not a listings UI.
  # Devise needs this as its post-sign-in destination too.
  root "home#index"

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
