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

  # Public root page: what this demo is + live DOMAIN activity (listing counts
  # read from philslist's own tables) + the PUBLIC classifieds board (open
  # listings across all owners — classifieds are public by nature, so a viewer
  # SEES a wire-posted listing appear). Writes still happen over the wire
  # (post_listing / edit_listing / close_listing); this page is read-only.
  # Devise needs this as its post-sign-in destination too.
  root "home#index"

  # Standalone, read-only classifieds board — the same open listings on their
  # own bookmarkable URL, a viewer can watch listings land under each owner.
  get "/listings", to: "home#listings"
end
