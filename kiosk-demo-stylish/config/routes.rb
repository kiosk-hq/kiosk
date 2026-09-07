# frozen_string_literal: true

Rails.application.routes.draw do
  # ── The Kiosk wire surface ────────────────────────────────────────────────
  # Mounted protocol plane + one explicit route per registered verb, drawn in
  # config/routes/kiosk.rb so the wire reads as one file and this one stays
  # this app's own pages. `draw` is Rails' own — config/routes/<name>.rb.
  draw(:kiosk)

  # Human sign-in (Devise) — the web session that approves assistant links.
  # The sessions controller is overridden ONLY to answer a JSON-shaped
  # `DELETE /users/sign_out` with a JSON courtesy body — deliberately NOT the
  # wire's RFC 9457 problem document, see the controller — instead of a
  # bodyless 401; every other Devise behaviour is inherited untouched.
  devise_for :users, controllers: { sessions: "users/sessions" }

  # Public root page: what this demo is + live DOMAIN activity (appointment
  # counts read from stylish's own tables) + both doors (human sign-in +
  # the Kiosk wire). Devise still needs this as its post-sign-in destination.
  root "home#index"

  # ─── Live-activity telemetry aggregate (opt-in) ─────────────────
  # Privacy-safe counts for the demo page + the kiosk.tech landing tile.
  # Drawn ONLY when KIOSK_TELEMETRY=1 so it is a no-op in CI/local flows.
  if ENV["KIOSK_TELEMETRY"] == "1"
    get "/demo/activity.json", to: "demo_activity#show", defaults: { format: :json }
  end
end
