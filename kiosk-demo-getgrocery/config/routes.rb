# frozen_string_literal: true

Rails.application.routes.draw do
  # Human sign-in (Devise): the web session that approves assistant links.
  devise_for :users, controllers: { sessions: 'kiosk/user_identity_providers/devise/sessions' }

  # Human storefront + the agent hook ("Agents → Kiosk here") on the homepage.
  # Devise needs this as its post-sign-in destination too.
  root 'home#index'

  # Crawlers: robots.txt names the sitemap.
  get '/robots.txt', to: 'crawler#robots'
  get '/sitemap.xml', to: 'crawler#sitemap'

  # ── The Kiosk HTTP API surface ────────────────────────────────────────────────
  kiosk do
    queries :catalog, :delivery_slots, :my_orders
    actions :create_order, :reschedule_delivery
  end

  # ─── Provider admin (read-only demo back-office) ──────────────────────────
  # No auth required — demo provider only. Production would authenticate.
  get '/admin/orders' => 'admin/orders#index', as: :admin_orders
end
