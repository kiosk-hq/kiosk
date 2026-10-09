# frozen_string_literal: true

Rails.application.routes.draw do
  # Human sign-in (Devise): the web session that approves assistant links.
  devise_for :users, controllers: { sessions: "kiosk/user_identity_providers/devise/sessions" }

  # Human storefront + the agent hook ("Agents → Kiosk here") on the homepage.
  # Devise needs this as its post-sign-in destination too.
  root "home#index"

  # ── The Kiosk wire surface ────────────────────────────────────────────────
  # Mounted protocol plane + one explicit route per registered verb, drawn in
  # config/routes/kiosk.rb so the wire reads as one file and this one stays
  # this app's own pages. `draw` is Rails' own — config/routes/<name>.rb.
  draw(:kiosk)

  # ─── Provider admin (read-only demo back-office) ──────────────────────────
  # No auth required — demo provider only. Production would authenticate.
  get "/admin/orders" => "admin/orders#index", as: :admin_orders
end
