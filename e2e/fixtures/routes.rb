# frozen_string_literal: true

require "json"

Rails.application.routes.draw do
  # Kiosk wire surface (controllers shipped by kiosk-server).
  # In a follow-up release these will be mounted via the engine's own
  # routes drawer; for v0.1 alpha we wire them manually here.
  post "/kiosk/exec",                              to: "kiosk/server/exec#exec"
  get  "/kiosk/.well-known/jwks.json",             to: "kiosk/server/jwks#show"
  post "/kiosk/oauth/device_authorization",        to: "kiosk/server/oauth_device_authorization#create"
  post "/kiosk/oauth/token",                       to: "kiosk/server/oauth_token#create"

  # /.well-known/kiosk.json discovery endpoint — built on the fly from
  # Kiosk.configuration. Inlined here since kiosk-server doesn't yet
  # ship a controller for it.
  get "/.well-known/kiosk.json", to: ->(env) {
    base_url = "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}"
    doc = Kiosk::Server::WellKnown.build_json(base_url: base_url)
    [200, { "content-type" => "application/json" }, [doc]]
  }

  # ─── E2e-only test fixtures ──────────────────────────────────────────
  # Simulates user approval / denial at /oauth/device/verify. The real
  # verification controller (HTML form + consent screen + Devise login)
  # lands in Device-Grant sub-slice 3; this fixture lets sub-slice-2's
  # e2e exercise the full polling → approved → JWT chain without a
  # browser in the loop.
  if Rails.env.development?
    post "/kiosk/_test/device_authorization/approve", to: ->(env) {
      request = Rack::Request.new(env)
      user_code = request.params["user_code"].to_s.tr("-", "")
      user_id   = request.params["user_id"].to_s

      store = Kiosk.configuration.device_authorization_store
      da    = store.find_by_user_code(user_code)
      if da.nil?
        [404, { "content-type" => "application/json" },
         [JSON.generate(ok: false, error: "user_code not found or already acted on")]]
      else
        store.update(da.approve(user_id: user_id))
        [200, { "content-type" => "application/json" },
         [JSON.generate(ok: true, status: "approved")]]
      end
    }
  end
end
