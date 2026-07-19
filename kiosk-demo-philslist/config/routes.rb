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
  # unlinks, and edits per-assistant label + spending cap (ADR-0017/0019).
  get  "/kiosk/auth/assistants",                   to: "kiosk/server/assistants#show"
  post "/kiosk/auth/assistants/link",              to: "kiosk/server/assistants#link"
  post "/kiosk/auth/assistants/unlink",            to: "kiosk/server/assistants#unlink"
  post "/kiosk/auth/assistants/update",            to: "kiosk/server/assistants#update"

  # Human sign-in (Devise) — the web session that approves assistant links.
  devise_for :users

  # Minimal landing page (api-only in spirit — NO public HTML listings index,
  # by design): Devise needs a post-sign-in destination, and a human landing
  # here should learn where both doors are. The board itself is read over the
  # Kiosk wire (browse_listings), shown via curl + jq in the demo — not HTML.
  root to: proc { |_env|
    [200, { "content-type" => "text/html; charset=utf-8" },
     ["<!DOCTYPE html><html><head><meta charset='utf-8'><title>philslist</title></head>" \
      "<body style='font-family:system-ui,sans-serif;text-align:center;padding:64px'>" \
      "<h1>philslist</h1><p>Kiosk demo classifieds board (no payments). Humans sign in at " \
      "<a href='/users/sign_in'>/users/sign_in</a>; assistants browse/post via the " \
      "Kiosk wire (see <a href='/.well-known/kiosk.json'>/.well-known/kiosk.json</a>).</p>" \
      "</body></html>"]]
  }

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
end
