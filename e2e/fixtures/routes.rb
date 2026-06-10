# frozen_string_literal: true

Rails.application.routes.draw do
  # Kiosk wire surface (controllers shipped by kiosk-server).
  # In a follow-up release these will be mounted via the engine's own
  # routes drawer; for v0.1 alpha we wire them manually here.
  post "/kiosk/exec",                 to: "kiosk/server/exec#exec"
  get  "/kiosk/.well-known/jwks.json", to: "kiosk/server/jwks#show"

  # /.well-known/kiosk.json discovery endpoint — built on the fly from
  # Kiosk.configuration. Inlined here since kiosk-server doesn't yet
  # ship a controller for it.
  get "/.well-known/kiosk.json", to: ->(env) {
    base_url = "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}"
    doc = Kiosk::Server::WellKnown.build_json(base_url: base_url)
    [200, { "content-type" => "application/json" }, [doc]]
  }
end
