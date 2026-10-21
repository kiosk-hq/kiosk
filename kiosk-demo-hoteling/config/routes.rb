# frozen_string_literal: true

Rails.application.routes.draw do
  # Human sign-in (Devise): the web session that approves assistant links.
  devise_for :users, controllers: { sessions: 'kiosk/user_identity_providers/devise/sessions' }

  # Public root page: what this demo is + live DOMAIN activity (booking counts
  # read from hoteling's own tables) + how an agent pokes the protocol. The app
  # carries the full middleware stack (Devise sessions), and HomeController
  # inherits ApplicationController so HTML renders.
  # Devise needs this as its post-sign-in destination too.
  root 'home#index'

  # Crawlers: robots.txt names the sitemap.
  get '/robots.txt', to: 'crawler#robots'
  get '/sitemap.xml', to: 'crawler#sitemap'

  # ── The Kiosk HTTP API surface ────────────────────────────────────────────────
  kiosk do
    queries :availability, :hotel_detail, :my_bookings, :properties, :search_hotels
    actions :reserve_room
  end
end
