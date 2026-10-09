# frozen_string_literal: true

Rails.application.routes.draw do

  # Human sign-in (Devise): the web session that approves assistant links.
  devise_for :users, controllers: { sessions: "kiosk/user_identity_providers/devise/sessions" }

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
end
