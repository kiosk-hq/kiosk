# frozen_string_literal: true

Rails.application.routes.draw do

  # Human diner sign-in (Devise) — the web session that mints the link code a
  # diner uses to bind their AI assistant to their restaurant account. Walked
  # end-to-end by `rake demo:binding`. The sessions controller is overridden
  # ONLY to answer a JSON-shaped `DELETE /users/sign_out` with a JSON courtesy
  # body pointing at the wire, instead of a bodyless 401. That body is NOT «the
  # Kiosk error envelope»: that phrase names the wire CONTRACT, and the wire's
  # is a FLAT RFC 9457 problem document served as `application/problem+json` —
  # see `app/controllers/users/sessions_controller.rb`, which says the same
  # thing at the render site. Every other Devise behaviour is inherited
  # untouched.
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

  # ── The Kiosk wire surface ────────────────────────────────────────────────
  # Mounted protocol plane + one explicit route per registered verb, drawn in
  # config/routes/kiosk.rb so the wire reads as one file and this one stays
  # this app's own pages. `draw` is Rails' own — config/routes/<name>.rb.
  draw(:kiosk)

  # ─── Live-activity telemetry aggregate (opt-in) ─────────────────
  # Privacy-safe counts for the demo page + the kiosk.tech landing tile.
  # Drawn ONLY when KIOSK_TELEMETRY=1 so it is a no-op in CI/local flows.
  if ENV["KIOSK_TELEMETRY"] == "1"
    get "/demo/activity.json", to: "demo_activity#show", defaults: { format: :json }
  end
end
