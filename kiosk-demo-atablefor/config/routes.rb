# frozen_string_literal: true

Rails.application.routes.draw do

  # Human diner sign-in (Devise) — the web session that mints the link code a
  # diner uses to bind their AI assistant to their restaurant account. Walked
  # end-to-end by `rake demo:binding`. The sessions controller is overridden
  # ONLY to answer a JSON-shaped `DELETE /users/sign_out` with a JSON courtesy
  # body pointing at the wire, instead of a bodyless 401 (K-533). NOT «the Kiosk
  # error envelope», which is what this comment used to call it: that phrase
  # names the wire CONTRACT, and the wire's is a FLAT RFC 9457 problem document
  # served as `application/problem+json` (K-1092) — see
  # `app/controllers/users/sessions_controller.rb`, which says the same thing at
  # the render site. Every other Devise behaviour is inherited untouched.
  devise_for :users, controllers: { sessions: "users/sessions" }

  # Public root page: what this demo is + the assistant-facing "point your AI
  # assistant here" cue + a live, read-only reservations board (upcoming
  # bookings read from atablefor's own tables, shown under each diner's name).
  # HomeController inherits ActionController::Base so HTML renders.
  root "home#index"

  # Public, read-only reservations board — the (b) reveal: after an assistant
  # books + links, the reservation shows up here under the diner's name. Shares
  # HomeController#reservations so the board renders both on the home page and
  # on its own /reservations URL.
  get "/reservations", to: "home#reservations"

  # Account binding: the human half (link mint, verify page, unlink — the
  # Devise session channel) and the agent half (link-code redeem). Walked
  # end-to-end by `rake demo:binding`: a diner mints a link code, their
  # assistant redeems it, and the assistant's bookings tie to the diner.
  get  "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#show"
  post "/kiosk/oauth/device/verify",               to: "kiosk/server/device_verify#create"
  post "/kiosk/auth/link",                         to: "kiosk/server/auth#link"
  post "/kiosk/auth/claim",                        to: "kiosk/server/auth#claim"
  post "/kiosk/auth/unlink",                       to: "kiosk/server/auth#unlink"
  get  "/auth.md",                                 to: "kiosk/server/discovery#auth_md"

  # «Manage assistants» HTML page (kiosk-server AssistantsController): a
  # signed-in diner lists their bound assistants, mints link codes (shown
  # once), unlinks, and relabels. Reused wholesale from the engine (it ships
  # the view) — atablefor does NOT rebuild it. This is the human UI the diner
  # uses to mint the code their assistant then redeems over the wire.
  get  "/kiosk/auth/assistants",                   to: "kiosk/server/assistants#show"
  post "/kiosk/auth/assistants/link",              to: "kiosk/server/assistants#link"
  post "/kiosk/auth/assistants/unlink",            to: "kiosk/server/assistants#unlink"
  post "/kiosk/auth/assistants/update",            to: "kiosk/server/assistants#update"
  # Kiosk wire surface (controllers shipped by kiosk-server).
  # REST endpoints: one per verb, HTTP method = semantics.
  get  "/kiosk/schema",                            to: "kiosk/server/wire#schema"
  # NO `POST /kiosk/query` or `POST /kiosk/run` — protocol 0.4 deleted the
  # multiplexed pair outright (T-074 = A). Every verb is its own endpoint; the
  # pair that serves them is drawn LAST, at the bottom of this file.
  # `pay` IS drawn here, and atablefor configures NO payment_provider — the same
  # unconditional line the engine's own routes drawer lays down, kept so a
  # hand-mounted host and a mounted engine expose the identical table. It is not
  # a claim that this origin takes money: discovery drops `pay` from
  # `capabilities`, `demo:schema` asserts its absence, and the endpoint answers
  # `403 no payment_provider configured` on the FIRST look — before it asks for
  # mandates it could never settle (K-800).
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

  # /kiosk/openapi.json — the DERIVED OpenAPI description of the per-verb wire
  # (T-071 = C). It MUST be drawn above the per-verb pair: Rails appends
  # `(.:format)` to `/kiosk/:kiosk_verb`, so without this line the path reads as
  # the verb `openapi` in the `json` format and answers 404.
  get "/kiosk/openapi.json",                to: "kiosk/server/open_api#show"

  # ── The 0.4 per-verb wire ────────────────────────────────────────────────
  #
  # One endpoint per registered verb: GET /kiosk/<query-name>,
  # POST /kiosk/<action-name>. atablefor hand-draws its routes rather than
  # mounting the engine (that IS the escape hatch the engine documents), so the
  # pair the engine would have drawn is written out here — and, like the
  # engine's, LAST, so every reserved line above wins by first-match and no
  # operator verb can shadow `schema`, `pay` or the auth plane.
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
