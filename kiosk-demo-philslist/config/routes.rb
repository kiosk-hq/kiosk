# frozen_string_literal: true

Rails.application.routes.draw do
  # ── The Kiosk HTTP API surface ────────────────────────────────────────────────
  kiosk do
    queries :browse_listings, :my_listings
    actions :close_listing, :edit_listing, :post_listing
  end

  # Human sign-in (Devise): the web session that approves assistant links.
  devise_for :users, controllers: { sessions: 'kiosk/user_identity_providers/devise/sessions' }

  # Public root page: what this demo is + live DOMAIN activity (listing counts
  # read from philslist's own tables) + the PUBLIC classifieds board (open
  # listings across all owners — classifieds are public by nature, so a viewer
  # SEES an API-posted listing appear). Writes still happen over HTTP
  # (post_listing / edit_listing / close_listing); this page is read-only.
  # Devise needs this as its post-sign-in destination too.
  root 'home#index'

  # Crawlers: robots.txt names the sitemap.
  get '/robots.txt', to: 'crawler#robots'
  get '/sitemap.xml', to: 'crawler#sitemap'

  # Standalone, read-only classifieds board — the same open listings on their
  # own bookmarkable URL, a viewer can watch listings land under each owner.
  get '/listings', to: 'home#listings'
end
