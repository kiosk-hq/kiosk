# frozen_string_literal: true

Rails.application.routes.draw do
  # ── The Kiosk wire surface ────────────────────────────────────────────────
  # Mounted protocol plane + one explicit route per registered verb, drawn in
  # config/routes/kiosk.rb so the wire reads as one file and this one stays
  # this app's own pages. `draw` is Rails' own — config/routes/<name>.rb.
  draw(:kiosk)

  # Human sign-in + sign-up (Devise) — the web session that approves assistant
  # links, and the open registration tudu alone in the fleet offers.
  # The sessions controller is overridden ONLY to answer a JSON-shaped
  # `DELETE /users/sign_out` with a JSON courtesy body — deliberately NOT the
  # wire's RFC 9457 problem document, see the controller — instead of a
  # bodyless 401; the registrations controller ONLY to permit `display_name`
  # on sign-up (the roster publishes that column, never the address). Every
  # other Devise behaviour is inherited untouched.
  devise_for :users, controllers: { sessions: "users/sessions", registrations: "users/registrations" }

  # ── tudu web UI (the video centerpiece — tutorial-plain scaffold) ──────────
  # A signed-in human sees their lists, opens one to see todos + members, adds
  # todos, completes them, and mints an invite code. These thin controllers set
  # the GUC principal for the signed-in human and run the SAME domain logic the
  # wire actions run, so the human and the agent see one shared world.
  resources :lists, only: %i[index show create] do
    member do
      post "invite"
    end
    resources :todos, only: %i[create] do
      member { post "complete" }
    end
  end

  # root → a simple tudu landing pointing at sign-in + the wire, plus the public
  # housemate board (the collaboration reveal).
  root to: "lists#index"

  # Public, read-only HOUSEMATE view — the (b) reveal: after an assistant creates
  # a list and shares it with the housemate (Bob), the shared list shows up here
  # under his account. A viewer SEES the collaboration land without a second
  # identity store. Shares ListsController#shared with the home-page board.
  get "/shared", to: "lists#shared"
end
