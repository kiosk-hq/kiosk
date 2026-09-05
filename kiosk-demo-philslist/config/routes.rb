# frozen_string_literal: true

Rails.application.routes.draw do
  # Kiosk wire surface (controllers shipped by kiosk-server).
  # REST endpoints: one per verb, HTTP method = semantics.
  get  "/kiosk/schema",                            to: "kiosk/server/wire#schema"
  # NO `POST /kiosk/query` or `POST /kiosk/run` — protocol 0.4 deleted the
  # multiplexed pair outright (T-074 = A). Every verb is its own endpoint; the
  # pair that serves them is drawn LAST, at the bottom of this file.
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
  # The sessions controller is overridden ONLY to answer a JSON-shaped
  # `DELETE /users/sign_out` with a JSON courtesy body — deliberately NOT the
  # wire's RFC 9457 problem document, see the controller — instead of a
  # bodyless 401; every other Devise behaviour is inherited untouched.
  devise_for :users, controllers: { sessions: "users/sessions" }

  # Public root page: what this demo is + live DOMAIN activity (listing counts
  # read from philslist's own tables) + the PUBLIC classifieds board (open
  # listings across all owners — classifieds are public by nature, so a viewer
  # SEES a wire-posted listing appear). Writes still happen over the wire
  # (post_listing / edit_listing / close_listing); this page is read-only.
  # Devise needs this as its post-sign-in destination too.
  root "home#index"

  # Standalone, read-only classifieds board — the same open listings on their
  # own bookmarkable URL, a viewer can watch listings land under each owner.
  get "/listings", to: "home#listings"

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

  # /kiosk/openapi.json — the DERIVED OpenAPI description of the per-verb wire.
  # It MUST be drawn above the per-verb pair: Rails appends
  # `(.:format)` to `/kiosk/:kiosk_verb`, so without this line the path reads as
  # the verb `openapi` in the `json` format and answers 404.
  get "/kiosk/openapi.json",                to: "kiosk/server/open_api#show"

  # ── The 0.4 per-verb wire ────────────────────────────────────────────────
  #
  # One endpoint per registered verb: GET /kiosk/<query-name>,
  # POST /kiosk/<action-name>. philslist hand-draws its routes rather than
  # mounting the engine (that IS the escape hatch the engine documents), so the
  # pair the engine would have drawn is written out here — and, like the
  # engine's, LAST, so every reserved line above wins by first-match and no
  # operator verb can shadow `schema` or the auth plane.
  get  "/kiosk/:kiosk_verb", to: "kiosk/server/verb#show",
       constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
  post "/kiosk/:kiosk_verb", to: "kiosk/server/verb#create",
       constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }

  # ─── Live-activity telemetry aggregate (opt-in) ─────────────────
  # Privacy-safe counts for the demo page + the kiosk.tech landing tile.
  # Drawn ONLY when KIOSK_TELEMETRY=1 so it is a no-op in CI/local flows.
  if ENV["KIOSK_TELEMETRY"] == "1"
    get "/demo/activity.json", to: "demo_activity#show", defaults: { format: :json }
  end
end
