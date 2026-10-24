# frozen_string_literal: true

Rails.application.routes.draw do
  # Human sign-in (Devise): the web session that approves assistant links.
  devise_for :users

  # Public root page: what this demo is + the assistant-facing "point your AI
  # assistant here" cue + a live, read-only reservations board (upcoming
  # bookings read from atablefor's own tables, shown under each diner's name).
  # HomeController inherits ActionController::Base so HTML renders.
  root 'home#index'

  # Crawlers: robots.txt names the sitemap.
  get '/robots.txt', to: 'crawler#robots'
  get '/sitemap.xml', to: 'crawler#sitemap'

  # Public, read-only reservations board — the (b) reveal: after an assistant
  # books + links, the reservation shows up here under the diner's name. Shares
  # HomeController#reservations so the board renders both on the home page and
  # on its own /reservations URL.
  get '/reservations', to: 'home#reservations'

  # ── The Kiosk HTTP API surface ────────────────────────────────────────────────
  kiosk do
    queries :availability, :my_bookings
    actions :book_table, :cancel_booking
  end
end
