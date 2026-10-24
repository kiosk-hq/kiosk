# frozen_string_literal: true

Rails.application.routes.draw do
  # Human sign-in (Devise): the web session that approves assistant links.
  devise_for :users

  # Public root page: what this demo is + live DOMAIN activity (fleet + rental
  # counts read from skooti's own tables) + how an agent pokes the protocol. The app
  # carries the full middleware stack (Devise sessions), and HomeController
  # inherits ApplicationController so HTML renders.
  # Devise needs this as its post-sign-in destination too.
  root 'home#index'

  # What this demo stores and for how long.
  get '/privacy', to: 'privacy#show'

  # Crawlers: robots.txt names the sitemap.
  get '/robots.txt', to: 'crawler#robots'
  get '/sitemap.xml', to: 'crawler#sitemap'

  # The page a rental verb's `unlock_url` opens, and the App Clip's launch URL.
  get '/unlock', to: 'unlock#show'

  # ── The Kiosk HTTP API surface ────────────────────────────────────────────────
  kiosk do
    queries :my_reservations, :scooters_available
    actions :rent_motorcycle, :reserve, :start_rental
  end
end
